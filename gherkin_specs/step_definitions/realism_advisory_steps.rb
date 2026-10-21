# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

# PRD 0007 B3 · ticket #110. Realism was the LAST veto in the render stack. These steps
# drive the REAL gate and the REAL selector -- the scorer is stood in for at the
# subprocess boundary (a shell script where bin/aesthetics_gate.py would be), so the
# scenario asserts the advisory contract without needing the NAS model or the ComfyUI
# venv, neither of which exists in CI.

# The gate reads ONE JSON line from the scorer's stdout. `decision` is derived from the
# same thresholds and is deliberately NOT read by the gate any more, which is why it is
# still emitted here -- and still says reject.
def cuke_fake_aesthetic_scorer(aesthetic:, sharpness:)
  path = Rails.root.join('tmp', "cuke_aesthetic_scorer_#{SecureRandom.hex(6)}.sh").to_s
  payload = {
    path: '/tmp/cuke.png',
    aesthetic_score: aesthetic.to_f,
    sharpness: sharpness.to_f,
    decision: aesthetic.to_f >= 4.5 && sharpness.to_f >= 30.0 ? 'accept' : 'reject',
    reason: "aesthetic #{aesthetic} < 4.5",
    error: nil
  }.to_json
  File.write(path, "#!/bin/sh\nprintf '%s\\n' '#{payload}'\n")
  File.chmod(0o755, path)
  path
end

def cuke_library_photo!(persona:, pillar:, aesthetic_score:, sharpness:, created_at:)
  path = Rails.root.join('tmp', "cuke_realism_asset_#{SecureRandom.hex(6)}.png").to_s
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, 'not-really-a-png')
  @cuke_paths << path
  ContentPillars::Photo.create!(
    persona: persona, content_pillar: pillar, path: path, synthetic: true,
    aesthetic_score: aesthetic_score, sharpness: sharpness, created_at: created_at
  )
end

Given('a rendered image whose aesthetic score is {float} and sharpness is {float}') do |aesthetic, sharpness|
  @cuke_env = %w[AESTHETIC_MODEL_DIR AESTHETIC_GATE_SCRIPT AESTHETIC_PYTHON]
              .to_h { |k| [ k, ENV[k] ] }
  @cuke_model_dir = Dir.mktmpdir('cuke-aesthetic-model')
  @cuke_scorer_script = cuke_fake_aesthetic_scorer(aesthetic: aesthetic, sharpness: sharpness)
  # `/bin/sh` stands in for the python that would run the scorer: the gate only needs a
  # process that prints one JSON line, and CI has no ComfyUI venv.
  ENV['AESTHETIC_MODEL_DIR'] = @cuke_model_dir
  ENV['AESTHETIC_GATE_SCRIPT'] = @cuke_scorer_script
  ENV['AESTHETIC_PYTHON'] = '/bin/sh'

  @cuke_image = Rails.root.join('tmp', "cuke_realism_#{SecureRandom.hex(6)}.png").to_s
  FileUtils.mkdir_p(File.dirname(@cuke_image))
  File.binwrite(@cuke_image, 'not-really-a-png')
end

When('the realism measurement runs') do
  @cuke_result = Growth::RealismGate.new.call(image_path: @cuke_image)
end

Then('the result is measured and flagged') do
  expect(@cuke_result).to be_measured
  expect(@cuke_result.flagged).to be(true)
end

Then('the result offers no veto for a caller to act on') do
  expect(@cuke_result).not_to respond_to(:safe)
end

Given('a library holding a below-default asset and a sharp asset') do
  @cuke_paths = []
  @cuke_persona = create(:persona)
  @cuke_pillar = create(:content_pillar, persona: @cuke_persona)
  # The below-default asset is the NEWER of the two, so recency alone would put it
  # first: only the quality ordering can make it last.
  @cuke_soft = cuke_library_photo!(persona: @cuke_persona, pillar: @cuke_pillar,
                                   aesthetic_score: 3.2, sharpness: 12.4,
                                   created_at: 1.minute.ago)
  @cuke_sharp = cuke_library_photo!(persona: @cuke_persona, pillar: @cuke_pillar,
                                    aesthetic_score: 6.4, sharpness: 220.0,
                                    created_at: 5.minutes.ago)
end

When('the available photos are listed') do
  @cuke_listed = Photos::ListAvailable.call(persona: @cuke_persona).photos
end

Then('both assets are listed') do
  expect(@cuke_listed.map(&:id)).to contain_exactly(@cuke_soft.id, @cuke_sharp.id)
end

Then('the below-default asset is last') do
  expect(@cuke_listed.last.id).to eq(@cuke_soft.id)
end

Before('@DEV-0110') do
  ActiveRecord::Base.connection.begin_transaction(joinable: false)
end

After('@DEV-0110') do
  # Remove the throwaway fixtures BEFORE restoring the env that named them, or the
  # restore would leave the temp path in place and the delete would hit the real script.
  FileUtils.rm_rf(@cuke_model_dir) if @cuke_model_dir
  [ @cuke_image, @cuke_scorer_script, *(@cuke_paths || []) ].compact.each { |p| FileUtils.rm_f(p) }
  (@cuke_env || {}).each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  @cuke_env = @cuke_model_dir = @cuke_scorer_script = nil
  @cuke_paths = []
  # Same shared-DB hygiene as the wardrobe steps: cucumber-rails does not clean up by
  # default, and a leaked persona collides with the rspec sequence(:name) next run.
  ActiveRecord::Base.connection.rollback_transaction if ActiveRecord::Base.connection.transaction_open?
end
