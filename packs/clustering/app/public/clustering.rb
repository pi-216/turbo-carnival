# frozen_string_literal: true

# Public API for Clustering pack
module Clustering
  # Create a new cluster
  def self.create_cluster(persona:, name:, pillar: nil)
    cluster = Cluster.create!(
      persona: persona,
      name: name,
      status: :active
    )

    if pillar
      assign_to_pillar(cluster, pillar)
    end

    cluster
  end

  # Get clusters for a persona
  def self.for_persona(persona)
    Cluster.for_persona(persona.id)
  end

  # Assign cluster to pillar
  def self.assign_to_pillar(cluster, pillar, primary: false)
    PillarClusterAssignment.create!(
      cluster: cluster,
      pillar: pillar,
      primary: primary
    )
  end

  # Auto-link winner to cluster (called by pipeline on completion)
  def self.link_winner(run)
    LinkWinnerToCluster.call(run)
  end
end
