class JobOrchestrationConfig
  # N: Per-parent breadth-first - how many children to generate per parent
  # Creates balanced tree exploration: 2 → 4 → 8 → 16 → 32
  # Control growth by rejecting low-ELO candidates early
  def self.max_children_per_node
    ENV.fetch("MAX_CHILDREN_PER_NODE", "3").to_i
  end

  # K: How many candidates advance to next step by default
  # When approving a step, only top-K by ELO become eligible parents
  # Can be overridden per approval
  def self.default_top_k
    ENV.fetch("DEFAULT_TOP_K", "3").to_i
  end

  def self.target_leaf_nodes
    ENV.fetch("TARGET_LEAF_NODES", "10").to_i
  end
end
