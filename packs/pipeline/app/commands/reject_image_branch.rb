class RejectImageBranch < ApplicationCommand
  requires :image_candidate

  def call
    context.image_candidate.reject!
  end

  def rollback
    # GLCommand handles transaction rollback automatically
  end
end
