require 'rails_helper'

RSpec.describe "gap_analyses/index", type: :view do
  # PRD 0006 R1 / ticket #84: the view was converted ERB -> HAML. This is the
  # behavior-neutrality regression — the rendered markup must be semantically
  # unchanged by the template-handler swap (HAML emits single-quoted attributes).
  it "renders the index heading and placeholder text unchanged" do
    render template: "gap_analyses/index"
    expect(rendered).to include("GapAnalyses#index")
    expect(rendered).to include("Find me in app/views/gap_analyses/index.html")
    expect(rendered).to match(/<h1[^>]*class=(['"])font-bold text-4xl\1[^>]*>GapAnalyses#index<\/h1>/)
    expect(rendered).to include("Find me in app/views/gap_analyses/index.html.erb")
  end
end
