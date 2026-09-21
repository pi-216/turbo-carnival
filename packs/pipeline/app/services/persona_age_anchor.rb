# frozen_string_literal: true

# Give the persona's stored render prompt an explicit ADULT age anchor.
#
# WHY THIS EXISTS
# ---------------
# PipelinePromptSafety removes a minor DIRECTION and stops the render being
# conditioned against adulthood, but it deliberately never picks an age -- so the
# persona's age stayed undefined and the model filled the gap itself. Measured
# 2026-09-21: the production step's positive prompt (pipeline_steps 40, pipeline
# 21 'turbo-one-step-clean', the path Growth::ContentGenerator renders with)
# reads "petite face, small nose, s1_dram, sarah1a3" with NO age token anywhere,
# and independent vision reads of production renders returned "a young girl,
# likely a teenager" / "late teens or early twenties" / "early teens to early
# twenties". The operating agent's decision (2026-09-21, ops board
# persona-age-read-youthful) is that the persona IS an adult: an undefined age on
# a public adult-oriented account is a platform and legal risk, and the render
# prompt is the deterministic place to say so.
#
# This is the INPUT-side half of that decision; Growth::PersonaAgeGate is the
# OUTPUT-side half (it holds any queued render whose apparent-age read comes back
# juvenile, whatever the prompt said). Both exist because either one alone fails:
# a prompt anchor cannot catch a model that ignores it, and a gate alone wastes
# paid-for renders on an avoidable read.
#
# SCOPE: an anchor is APPENDED (prepended to the identity line, where SD-style
# prompts weight it most); no identity token is removed and no LoRA weight is
# changed. Those are creative choices about who Sarah is, not age facts, and they
# are not this task's business.
class PersonaAgeAnchor
  # The age the persona is stated to be. "late twenties" rather than a bare
  # number: a number is a directive the model renders literally, an age band is a
  # description of an adult appearance.
  ANCHOR = 'adult woman in her late twenties'

  # The identity line every persona prompt carries. Only a text value that names
  # the persona's identity token is a positive prompt -- the negative prompts
  # never name the persona.
  IDENTITY_MARKER = /sarah1a3/i

  # An age anchor already present: "adult", an age band, or a decade word.
  AGE_MARKER = /\badult\b|\b(?:2[0-9]|3[0-9])\s*(?:s\b|-)|late twenties|early thirties|thirties|forties/i

  Change = Struct.new(:node_id, :key, :before, :after) do
    def to_s
      "node #{node_id} (#{key}): #{before.inspect} -> #{after.inspect}"
    end
  end

  # Mutates and returns [workflow, changes]. Mirrors PipelinePromptSafety so the
  # task can use the same literal-replacement write.
  def self.anchor_workflow(workflow)
    new(workflow).anchor
  end

  def initialize(workflow)
    @workflow = workflow
    @changes = []
  end

  def anchor
    return [ @workflow, @changes ] unless @workflow.is_a?(Hash)

    @workflow.each do |node_id, node|
      next unless node.is_a?(Hash)

      inputs = node['inputs']
      next unless inputs.is_a?(Hash)

      inputs.each do |key, value|
        next unless value.is_a?(String)

        anchored = anchored_text(value)
        next if anchored.nil?

        @changes << Change.new(node_id.to_s, key, value, anchored)
        inputs[key] = anchored
      end
    end

    [ @workflow, @changes ]
  end

  # The anchored form of a prompt value, or nil when this value is not the
  # persona's positive prompt (or is already anchored).
  def anchored_text(text)
    return nil unless text.match?(IDENTITY_MARKER)
    return nil if text.match?(AGE_MARKER)

    # Put the anchor at the START of the identity line, keeping the line's own
    # tokens intact: "...\npetite face, small nose, s1_dram, sarah1a3\n..." ->
    # "...\nadult woman in her late twenties, petite face, small nose, s1_dram,
    # sarah1a3\n...".
    line = text[/^.*#{IDENTITY_MARKER.source}.*$/i]
    return nil if line.nil?

    text.sub(line) { "#{ANCHOR}, #{line}" }
  end
end
