# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationCommand do
  describe "#run_after_commit" do
    it "does not fire a side effect scheduled via run_after_commit when the transaction rolls back" do
      cmd = Class.new(ApplicationCommand) do
        def call
          @effects = []
          ActiveRecord::Base.transaction do
            run_after_commit { @effects << :fired }
            FactoryBot.create(:persona)
            raise ActiveRecord::Rollback
          end
          context
        end

        attr_reader :effects
      end.new

      cmd.call

      expect(cmd.effects).to be_empty
    end

    it "fires a side effect scheduled via run_after_commit when the transaction commits" do
      cmd = Class.new(ApplicationCommand) do
        def call
          @effects = []
          ActiveRecord::Base.transaction do
            run_after_commit { @effects << :fired }
            FactoryBot.create(:persona)
          end
          context
        end

        attr_reader :effects
      end.new

      cmd.call

      expect(cmd.effects).to eq([ :fired ])
    end

    it "runs the side effect immediately when no DB transaction is open" do
      cmd = Class.new(ApplicationCommand) do
        def call
          @effects = []
          run_after_commit { @effects << :fired }
          context
        end

        attr_reader :effects
      end.new

      # Every example runs inside RSpec's outer transactional fixture, so an
      # outer transaction is always open here. Force the no-transaction branch
      # so the immediate path is exercised rather than the deferred one.
      allow(ActiveRecord::Base.connection).to receive(:transaction_open?).and_return(false)

      cmd.call

      expect(cmd.effects).to eq([ :fired ])
    end
  end
end
