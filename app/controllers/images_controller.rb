class ImagesController < ApplicationController
  # image_path is minted by ComfyUI::ProcessJobResult into the ComfyUI output
  # tree (/mnt/fscache/essdee/ComfyUI/output/...). Brakeman flags send_file on
  # that DB-stored value, so serve only after proving it stays inside the roots
  # that writer uses (COMFYUI_MIRROR_ROOT + the ComfyUI output mounts). The
  # roots are read at request time so COMFYUI_MIRROR_ROOT can be set in tests.
  def show
    candidate = ImageCandidate.find(params[:id])

    roots = [
      ENV["COMFYUI_MIRROR_ROOT"],
      "/mnt/essdee/ComfyUI",
      "/mnt/fscache/essdee/ComfyUI"
    ].compact

    send_file_from_allowed_root(candidate.image_path,
                                allowed_roots: roots,
                                type: "image/png",
                                disposition: "inline")
  end
end
