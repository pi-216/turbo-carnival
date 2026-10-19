# frozen_string_literal: true

# Render-time prompt-safety guard.
#
# NOTE ON THE NAME: `Pipeline` is an ActiveRecord class, not a module, so this
# cannot live at Pipeline::PromptSafety -- nesting under it raises
# "TypeError: Pipeline is not a module". Hence the flat name.
#
# WHY THIS EXISTS
# ---------------
# A stored workflow is executable instruction text, and the stored text drifted
# into territory no render should enter. Measured live 2026-09-20:
#
#   * pipeline_steps 39/40 (pipelines 20 'turbo-one-step' -- the generator's
#     FALLBACK -- and 21 'turbo-one-step-clean', the production path) carry a
#     NEGATIVE prompt wired into the sampler that reads
#     "... long neck, adult, mature_face, sunken_eyes": the render is actively
#     conditioned AGAINST adult features, and independent vision reads of three
#     production renders returned "a young girl, likely a teenager".
#   * pipeline_steps 34 (pipeline 17 'sarah1a3', reachable from the admin UI via
#     ContentSuggestionsController#generate_image, which picks Pipeline.first)
#     carries an LLM node whose system instruction says, verbatim, "...change it
#     so the resulting image will be that of a white, Caucasian young teenager".
#
# Both are Pony-era boilerplate and a stale face step, not creative choices --
# and both are stored data, so a code-only fix cannot reach them. This class is
# the choke point instead: every render is submitted through
# BuildJobPayload, which runs the workflow through here before it becomes a
# ComfyUI payload. Stored text that directs a minor is rewritten, and a negative
# prompt that suppresses adult features is stripped, whatever the database holds.
#
# WHAT IT DELIBERATELY DOES NOT DO
# --------------------------------
# It never picks an AGE for the persona. "petite face, small nose" and the
# absence of an age in the positive prompt are the identity question Tim owns
# (board: persona-age-read-youthful); guessing there would silently change who
# Sarah is. The rules below are a SAFETY FLOOR only: no minor direction, no
# conditioning against adulthood.
class PipelinePromptSafety
    # Phrases that direct the model toward a MINOR. Deliberately narrow: an adult
    # can be young, petite or small-framed, so "young"/"petite" are NOT matched --
    # only terms that imply a child.
    JUVENILE_RULES = [
      [ /\byoung\s+teen(?:ager|aged)?s?\b/i, 'adult' ],
      [ /\bteenagers?\b/i, 'adult' ],
      [ /\bteen[-\s]?aged\b/i, 'adult' ],
      [ /\bteens?\b/i, 'adult' ],
      [ /\bpre[-\s]?teens?\b/i, 'adult' ],
      [ /\btweens?\b/i, 'adult' ],
      [ /\b(?:young|little|small)\s+girls?\b/i, 'adult woman' ],
      [ /\bschool\s?girls?\b/i, 'adult woman' ],
      [ /\badolescents?\b/i, 'adult' ],
      [ /\bunder[-\s]?aged?\b/i, 'adult' ],
      [ /\bminors?\b/i, 'adults' ],
      [ /\bchildren\b/i, 'adults' ],
      [ /\bchild\b/i, 'adult' ],
      [ /\bhigh[-\s]?school(?:ers?)?\b/i, 'adult' ],
      [ /\b\d{1,2}[-\s]?year[-\s]?olds?\b/i, 'adult' ]
    ].freeze

    # Tokens that suppress ADULT features when they appear in a NEGATIVE prompt.
    # Removing them can only move a render away from a juvenile read, and none of
    # them is an identity choice.
    ADULT_SUPPRESSING = [
      'adults?',
      'mature[_\s-]?face',
      'mature\s+wom[ae]n',
      'grown[-\s]?wom[ae]n',
      'elderly',
      'old\s+wom[ae]n'
    ].freeze

    ADULT_SUPPRESSING_RE = "(?<![a-z])(?:#{ADULT_SUPPRESSING.join('|')})(?![a-z])"
    ADULT_SUPPRESSING_RX = Regexp.new(ADULT_SUPPRESSING_RE, Regexp::IGNORECASE)

    # A prompt that carries classic negative boilerplate is a NEGATIVE prompt even
    # when the graph cannot prove it (a sampler input may be an indirection).
    NEGATIVE_BOILERPLATE = /worst quality|low quality|bad anatomy|score_5|score_4/i

    # Node inputs that can carry executable instruction text.
    TEXT_KEYS = %w[text prompt system string value positive negative].freeze

    # How far to follow conditioning indirections (sampler -> CLIPTextEncode ->
    # PreviewAny -> StringConcatenate -> Text Multiline is 4 hops in the live
    # turbo-one-step graph).
    MAX_DEPTH = 5

    SAMPLER_HINT = /sampler/i

    Change = Struct.new(:node_id, :role, :key, :kind, :before, :after) do
      def to_s
        "#{kind} in node #{node_id} (#{role}, #{key}): #{before.inspect} -> #{after.inspect}"
      end
    end

    # Mutates and returns [workflow, changes]. BuildJobPayload parses the workflow
    # fresh from the step's JSON, so mutating in place is safe there.
    def self.sanitize_workflow(workflow)
      new(workflow).sanitize
    end

    def initialize(workflow)
      @workflow = workflow
      @changes = []
    end

    def sanitize
      return [ @workflow, @changes ] unless @workflow.is_a?(Hash)

      roles = node_roles
      @workflow.each do |node_id, node|
        next unless node.is_a?(Hash)

        inputs = node['inputs']
        next unless inputs.is_a?(Hash)

        role = roles[node_id.to_s] || :unknown
        inputs.each do |key, value|
          inputs[key] = sanitize_value(value, node_id.to_s, role, key)
        end
      end
      [ @workflow, @changes ]
    end

    private

    def sanitize_value(value, node_id, role, key)
      case value
      when String
        sanitize_string(value, node_id, role, key)
      when Array
        value.map { |v| sanitize_value(v, node_id, role, key) }
      when Hash
        value.transform_values { |v| sanitize_value(v, node_id, role, key) }
      else
        value
      end
    end

    def sanitize_string(text, node_id, role, key)
      return text if text.empty?

      out = text.dup

      # 1. A minor direction is never acceptable, in any field, in any role --
      #    including an LLM node's system instruction.
      JUVENILE_RULES.each do |pattern, replacement|
        next unless out.match?(pattern)

        before = out
        out = out.gsub(pattern, replacement)
        @changes << Change.new(node_id, role, key, :juvenile_direction_removed, before, out)
      end

      # 2. Conditioning against adulthood is stripped from NEGATIVE prompts only.
      return out unless role == :negative || negative_boilerplate?(out)

      return out unless out.match?(ADULT_SUPPRESSING_RX)

      before = out
      out = strip_adult_suppression(out)
      @changes << Change.new(node_id, role, key, :adult_suppression_removed, before, out)
      out
    end

    def negative_boilerplate?(text)
      text.match?(NEGATIVE_BOILERPLATE)
    end

    # Remove the token AND its list separator, so "long neck, adult, mature_face,
    # sunken_eyes" becomes "long neck, sunken_eyes" rather than a doubled comma.
    def strip_adult_suppression(text)
      out = text.dup
      out = out.gsub(/#{ADULT_SUPPRESSING_RE}\s*,\s*/i, '')
      out = out.gsub(/,\s*#{ADULT_SUPPRESSING_RE}/i, '')
      out = out.gsub(/#{ADULT_SUPPRESSING_RE}/i, '')
      out
    end

    # Which nodes feed a sampler's positive / negative input. Title-based guessing
    # fails here: the live negative node is titled "CLIP Text Encode (Prompt)".
    def node_roles
      roles = {}
      @workflow.each do |node_id, node|
        next unless node.is_a?(Hash)

        next unless node['class_type'].to_s.match?(SAMPLER_HINT)

        inputs = node['inputs'] || {}
        %w[positive negative].each do |slot|
          ref = inputs[slot]
          next unless ref.is_a?(Array) && ref.first

          mark_role(roles, ref.first.to_s, slot.to_sym, 0)
        end
      end
      roles
    end

    def mark_role(roles, node_id, role, depth)
      return if depth > MAX_DEPTH
      return if roles[node_id] == role

      roles[node_id] = role
      node = @workflow[node_id]
      return unless node.is_a?(Hash)

      inputs = node['inputs'] || {}
      # A node that carries instruction text itself is the end of the chain; only
      # follow pure indirections (CLIPTextEncode -> PreviewAny -> concatenate).
      return if carries_text?(inputs)

      inputs.each_value do |value|
        next unless value.is_a?(Array) && value.first.is_a?(String)

        mark_role(roles, value.first, role, depth + 1)
      end
    end

  def carries_text?(inputs)
    inputs.any? do |key, value|
      value.is_a?(String) && !value.empty? && TEXT_KEYS.include?(key.to_s)
    end
  end
end
