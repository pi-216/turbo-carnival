class ApplicationController < ActionController::Base
  # Serves `path` ONLY when it resolves inside one of `allowed_roots`.
  #
  # Brakeman flags `send_file` fed directly from a DB-stored value (SendFile/Medium
  # 3.x): a compromised `path` column would serve an arbitrary file. The three
  # byte servers (ImagesController#show, MediaController#photo, MediaController#reel)
  # therefore prove the resolved path stays inside a root THIS app writes to
  # before the file is sent. Each column is minted by one writer into its own
  # mount, so the root set is that writer's mount(s); anything else is a 404.
  def send_file_from_allowed_root(path, allowed_roots:, **opts)
    resolved = File.expand_path(path.to_s)
    allowed = allowed_roots.compact.any? do |root|
      root = File.expand_path(root.to_s)
      resolved == root || resolved.start_with?(root + File::SEPARATOR)
    end
    return send_file(resolved, **opts) if allowed && File.file?(resolved)

    head :not_found
    nil
  end
end
