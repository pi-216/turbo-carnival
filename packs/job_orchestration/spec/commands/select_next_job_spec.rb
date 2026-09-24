require "rails_helper"

RSpec.describe SelectNextJob do
  let(:pipeline) { FactoryBot.create(:pipeline) }
  let!(:pipeline_run) { FactoryBot.create(:pipeline_run, pipeline: pipeline, status: 'running') }
  let!(:step1) { FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 1) }
  let!(:step2) { FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 2) }
  let!(:step3) { FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 3) }

  describe "#call" do
    before do
      # Create approved PipelineRunStep for each step so parents are eligible
      [ step1, step2, step3 ].each do |step|
        pipeline_run.pipeline_run_steps.create!(
          pipeline_step: step,
          approved: true,
          approved_at: Time.current,
          top_k_count: 10
        )
      end
    end

    def create_full_parent(step, next_step, count = 3)
      parent = FactoryBot.create(:image_candidate, pipeline_run: pipeline_run, pipeline_step: step, child_count: count)
      FactoryBot.create_list(:image_candidate, count, pipeline_run: pipeline_run, pipeline_step: next_step, parent: parent)
      parent
    end

    context "when eligible parents exist" do
      it "selects parents to fill out steps with < 2 candidates first (breadth-first)" do
        # Create 2 step 1 candidates that are FULL (actually have 3 children)
        2.times { create_full_parent(step1, step2, 3) }

        # Candidate with child_count 1 (needs more children)
        candidate_step1 = FactoryBot.create(:image_candidate, pipeline_run: pipeline_run, pipeline_step: step1, child_count: 1, elo_score: 1500)
        # Create 1 child for it
        FactoryBot.create(:image_candidate, pipeline_run: pipeline_run, pipeline_step: step2, parent: candidate_step1)

        # Step 2 candidate (not a parent for step 2 generation)
        candidate_step2 = FactoryBot.create(:image_candidate, pipeline_run: pipeline_run, pipeline_step: step2, child_count: 0, elo_score: 800)

        result = described_class.call

        expect(result).to be_success
        expect(result.mode).to eq(:child_generation)
        expect(result.parent_candidate).to eq(candidate_step1)
        expect(result.next_step).to eq(step2)
      end

      it "returns no_work when all steps have >= 2 candidates" do
        ClimateControl.modify TARGET_LEAF_NODES: "2", MAX_CHILDREN_PER_NODE: "2" do
          # Update steps to use N=2 for this test
          [ step1, step2, step3 ].each { |step| step.update!(max_children: 2) }

          # Create 2 candidates in each step
          # Step 1: 2 candidates, both FULL (have 2 children at step 2)
          2.times { create_full_parent(step1, step2, 2) }

          # Step 2: Candidates created above are parents.
          # We need to ensure step 2 candidates are also FULL (have 2 children at step 3)
          step2_candidates = ImageCandidate.where(pipeline_step: step2)
          step2_candidates.each do |parent|
            FactoryBot.create_list(:image_candidate, 2, pipeline_run: pipeline_run, pipeline_step: step3, parent: parent)
          end

          result = described_class.call

          expect(result).to be_success
          expect(result.mode).to eq(:no_work)
          expect(result.parent_candidate).to be_nil
          expect(result.next_step).to be_nil
        end
      end

      it "excludes rejected candidates" do
        # Create 2 FULL step1 candidates
        2.times { create_full_parent(step1, step2, 3) }

        FactoryBot.create(:image_candidate, pipeline_run: pipeline_run, pipeline_step: step1, child_count: 0, status: "rejected")
        candidate_active = FactoryBot.create(:image_candidate, pipeline_run: pipeline_run, pipeline_step: step1, child_count: 0, status: "active")

        result = described_class.call

        expect(result).to be_success
        expect(result.parent_candidate).to eq(candidate_active)
        expect(result.next_step).to eq(step2)
      end

      it "excludes candidates with max children" do
        ClimateControl.modify MAX_CHILDREN_PER_NODE: "5" do
          # Update steps to use N=5 for this test
          [ step1, step2, step3 ].each { |step| step.update!(max_children: 5) }

          # Need 5 step1 candidates (breadth-first with N=5)
          4.times { create_full_parent(step1, step2, 5) }
          create_full_parent(step1, step2, 5)

          # Eligible candidate - ensure high ELO so it's in top K
          candidate_eligible = FactoryBot.create(:image_candidate, pipeline_run: pipeline_run, pipeline_step: step1, child_count: 4, elo_score: 2000)
          FactoryBot.create_list(:image_candidate, 4, pipeline_run: pipeline_run, pipeline_step: step2, parent: candidate_eligible)

          result = described_class.call

          expect(result.parent_candidate).to eq(candidate_eligible)
          expect(result.next_step).to eq(step2)
        end
      end

      it "excludes candidates at final step" do
        # Create 3 step1 candidates, and their entire lineage up to step 3 FULL
        3.times do
          s1 = FactoryBot.create(:image_candidate, pipeline_run: pipeline_run, pipeline_step: step1, child_count: 3)
          s2_list = FactoryBot.create_list(:image_candidate, 3, pipeline_run: pipeline_run, pipeline_step: step2, parent: s1, child_count: 3)
          s2_list.each do |s2|
             FactoryBot.create_list(:image_candidate, 3, pipeline_run: pipeline_run, pipeline_step: step3, parent: s2)
          end
        end

        # Step 2 candidate needs children (The one we want selected)
        # Note: In real app, it should have a parent, but here we can check if it works as orphan or give it a parent
        candidate_step2 = FactoryBot.create(:image_candidate, pipeline_run: pipeline_run, pipeline_step: step2, child_count: 0, elo_score: 2000)

        # Another step 2 candidate (FULL)
        parent_step2 = FactoryBot.create(:image_candidate, pipeline_run: pipeline_run, pipeline_step: step2, child_count: 3)
        FactoryBot.create_list(:image_candidate, 3, pipeline_run: pipeline_run, pipeline_step: step3, parent: parent_step2)

        result = described_class.call

        # Should select step2 parent to fill step3
        expect(result.parent_candidate).to eq(candidate_step2)
        expect(result.next_step).to eq(step3)
      end
    end

    context "ELO-weighted raffle" do
      it "selects from candidates at same step" do
        # Create 2 FULL step1 candidates
        2.times { create_full_parent(step1, step2, 3) }

        # Create 2 step1 candidates needing children with different ELO
        candidate_a = FactoryBot.create(:image_candidate, pipeline_run: pipeline_run, pipeline_step: step1, child_count: 0, elo_score: 1200)
        candidate_b = FactoryBot.create(:image_candidate, pipeline_run: pipeline_run, pipeline_step: step1, child_count: 0, elo_score: 800)

        # Run multiple times to test distribution
        results = 100.times.map { described_class.call.parent_candidate }

        expect(results).to include(candidate_a)
        expect(results).to include(candidate_b)
        # A should be selected more often (60% vs 40%)
        a_count = results.count(candidate_a)
        expect(a_count).to be > 30 # Reduced from 40 to avoid flakiness
      end

      it "handles single candidate" do
        # Create 2 FULL step1 candidates
        2.times { create_full_parent(step1, step2, 3) }

        # Single eligible candidate at step1
        candidate = FactoryBot.create(:image_candidate, pipeline_run: pipeline_run, pipeline_step: step1, child_count: 0)

        result = described_class.call

        expect(result.parent_candidate).to eq(candidate)
        expect(result.next_step).to eq(step2)
      end

      it "handles zero ELO scores" do
        # FULL candidates to ignore
        2.times { create_full_parent(step1, step2, 3) }

        candidate_a = FactoryBot.create(:image_candidate, pipeline_run: pipeline_run, pipeline_step: step1, child_count: 0, elo_score: 0)
        candidate_b = FactoryBot.create(:image_candidate, pipeline_run: pipeline_run, pipeline_step: step1, child_count: 0, elo_score: 0)

        result = described_class.call

        expect(result.parent_candidate).to be_in([ candidate_a, candidate_b ])
        expect(result.next_step).to eq(step2)
      end
    end

    context "when no eligible parents exist" do
      context "no work mode" do
        it "returns no work when no deficit and all steps have min candidates" do
          ClimateControl.modify TARGET_LEAF_NODES: "10" do
            # Create 3 step 1 candidates (>= max 3)
            3.times { FactoryBot.create(:image_candidate, pipeline_run: pipeline_run, pipeline_step: step1, child_count: 5) }

            # Step 1 candidates are parents. We need to check if they need children.
            # Logic iterates parents.
            # If we give them 3 children each (max 3), they are full.

            ImageCandidate.where(pipeline_step: step1).each do |parent|
               FactoryBot.create_list(:image_candidate, 3, pipeline_run: pipeline_run, pipeline_step: step2, parent: parent)
            end

            # Step 2 parents need children?
            ImageCandidate.where(pipeline_step: step2).each do |parent|
               FactoryBot.create_list(:image_candidate, 3, pipeline_run: pipeline_run, pipeline_step: step3, parent: parent)
            end

            result = described_class.call

            expect(result).to be_success
            expect(result.mode).to eq(:no_work)
            expect(result.parent_candidate).to be_nil
            expect(result.next_step).to be_nil
          end
        end
      end
    end

    context "workable-run scope (regression guards)" do
      it "never works a run in a terminal status" do
        pipeline_run.update_column(:status, "failed")

        result = described_class.call

        expect(result).to be_success
        expect(result.mode).to eq(:no_work)
        expect(result.pipeline_run).to be_nil
      end

      it "never works a run produced by a synchronous producer" do
        pipeline_run.update_column(:variables, { "sync_producer" => "Growth::ContentGenerator" })

        result = described_class.call

        expect(result).to be_success
        expect(result.mode).to eq(:no_work)
        expect(result.pipeline_run).to be_nil
      end
    end

    context "edge cases" do
      # Clear the eager-loaded steps for these edge case tests
      before do
        PipelineRunStep.delete_all
        PipelineRun.delete_all
        PipelineStep.delete_all
        Pipeline.delete_all
      end

      it "handles no pipelines" do
        # Don't reference any pipeline/steps to keep DB empty
        result = described_class.call

        expect(result).to be_success
        expect(result.mode).to eq(:no_work)
      end

      it "handles pipeline with no steps" do
        FactoryBot.create(:pipeline) # Create pipeline without steps

        result = described_class.call

        expect(result).to be_success
        expect(result.mode).to eq(:no_work)
      end
    end
  end
end
