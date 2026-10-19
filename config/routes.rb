Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # API endpoints
  namespace :api do
    resources :campaigns, only: [ :create ]
  end

  # Mount importmap for JavaScript modules
  mount Importmap::Engine, at: "/importmap"

  # Mount Lookbook in development for component previews
  if Rails.env.development?
    mount Lookbook::Engine, at: "/lookbook"
  end

  # Dashboard (main entry point)
  root "dashboard#index"

  # Growth harness dashboard
  get "growth", to: "growth#index", as: :growth
  post "growth/:goal_id/sync_cadence", to: "growth#sync_cadence", as: :growth_run_cadence
  post "growth/:goal_id/snapshot", to: "growth#snapshot", as: :growth_snapshot
  post "growth/:goal_id/review", to: "growth#review", as: :growth_review

  # Personas
  resources :personas

  # Runs dashboard (main entry point)
  resources :runs, only: [ :index, :show, :new, :create ] do
    member do
      post :complete  # POST /runs/14/complete
      get :winners    # GET /runs/14/winners
      get :card       # GET /runs/14/card (for Turbo Frame refresh)
    end

    # Voting scoped to run
    get "vote", to: "image_votes#show"           # GET  /runs/14/vote
    post "vote", to: "image_votes#vote"          # POST /runs/14/vote
    post "vote/reject/:id", to: "image_votes#reject", as: :reject_vote
    # POST /runs/14/vote/reject/123

    # Gallery scoped to run
    get "gallery", to: "gallery#index"            # GET /runs/14/gallery?step=2
    post "gallery/reject/:id", to: "gallery#reject", as: :gallery_reject
    # POST /runs/14/gallery/reject/123
    post "steps/:step_id/approve", to: "gallery#approve_step", as: :approve_step
    # POST /runs/14/steps/2/approve
  end

  # Image candidate winner selection (global, works from any context)
  resources :image_candidates, only: [] do
    member do
      post :select_winner
      delete :unselect_winner
    end
  end

  # Legacy routes (redirect to first active run)
  get "vote" => "redirects#vote"
  get "gallery" => "redirects#gallery"

  # Winners gallery
  get "winners" => "winners#index", as: :winners

  # Image serving (global, no run scope needed)
  get "images/:id" => "images#show", as: :candidate_image

  # Photo media (served from NAS/local disk, no B2) — used for Instagram URLs
  get "media/photos/:id" => "media#photo", as: :media_photo

  # Reel media (a REELS post's MP4, served from local disk, no B2) — the
  # `video_url` Instagram::Client#create_reel fetches. Keyed on the POST, so the
  # withhold rule is the still path's: bytes are served only while the post that
  # references them exists.
  get "media/reels/:id" => "media#reel", as: :media_reel

  # Defines the root path route ("/")

  # Personas navigation
  resources :personas, only: [ :index, :show, :new, :create ] do
    # Gap analyses
    resources :gap_analyses, only: [ :index, :show, :create ]

    # Content suggestions
    resources :content_suggestions, only: [ :index ]

    # LLM Campaigns
    resources :campaigns, only: [ :index, :show ], controller: "personas/campaigns"

    # Nested pillars
    resources :pillars, only: [ :show, :new, :create, :edit, :update, :destroy ], controller: "content_pillars" do
      member do
        get :suggest
      end

      resources :photos, only: [ :new, :create ], controller: "pillar_photos"
    end

    # Scheduling and Posts
    namespace :scheduling do
      resources :posts, only: [ :index, :new, :create, :destroy ] do
        member do
          post :suggest_caption
        end
        collection do
          post :suggest_next
          get :browse_photos
        end
      end
    end
  end

  # Content suggestions
  resources :content_suggestions, only: [] do
    member do
      get :edit
      patch :update
      post :use
      post :reject
      delete :destroy
      post :generate_image
    end
  end
end
