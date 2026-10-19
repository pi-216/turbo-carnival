# frozen_string_literal: true

# The base checkpoint a render may load, as a CLOSED set.
#
# WHY THIS EXISTS
# ---------------
# The workflow's base model used to be a hardcoded string inside
# `pipeline_steps.comfy_workflow_json` -- a Postgres text column with no git
# history. That is exactly how the identity prompt silently drifted: an agent
# rewrote node 88 of a "clean" copy into "fully clothed, modest", wired that
# copy into production, and no review could have seen it (measured 2026-10-18,
# see docs/strategy-v2.md). A base model is an EXPERIMENT VARIABLE, not a
# constant -- swapping it is the founder's live discovery work -- so it has to
# be (a) addressable per run and (b) bounded to what the founder approved.
#
# ALLOWED mirrors /mnt/nas-ai-models/checkpoints/pony/, which holds exactly
# these five files and nothing else. So the list states the founder's approved
# base set; it is not a judgement about quality.
#
# NOT A TASTE GATE. Quality is measured and ranked by controls (elo, AuraFace,
# engagement) and never vetoed here. This fails closed only on a checkpoint the
# founder has not approved -- which would otherwise surface as a cryptic ComfyUI
# "file not found" after a multi-minute model load.
module PipelineCheckpointAllowlist
  # Known-good baseline: the founder reports very good results with this one, and
  # it is what every existing production render used. An unparameterised run
  # therefore behaves exactly as production did.
  DEFAULT = 'Pornmaster_v2551619.safetensors'

  ALLOWED = [
    'CRPv18_PM25.safetensors',
    'CRPv18_PM40.safetensors',
    DEFAULT,
    'cyberrealisticPony_v180Coreshift.safetensors',
    'cyberrealisticponyV85.TgCf.safetensors'
  ].freeze

  class NotAllowed < StandardError; end

  module_function

  def allowed?(name)
    ALLOWED.include?(name.to_s)
  end

  # Resolve the checkpoint for a run.
  #
  # blank -> the known-good baseline, so a workflow that parameterises its base
  # model still renders if the run names nothing (and never ships a literal
  # "{{checkpoint}}" into ComfyUI as the filename).
  # named -> must be in ALLOWED, otherwise raise.
  #
  # @return [String] a filename safe to hand to ComfyUI
  def resolve!(name)
    value = name.to_s.strip
    return DEFAULT if value.empty?
    return value if allowed?(value)

    raise NotAllowed,
          "checkpoint #{value.inspect} is not in the approved set. " \
          "Approved: #{ALLOWED.join(', ')}. " \
          'Add one to PipelineCheckpointAllowlist::ALLOWED only after the founder approves it.'
  end
end
