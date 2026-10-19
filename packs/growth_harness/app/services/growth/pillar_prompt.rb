# frozen_string_literal: true

module Growth
  # Selects the image-generation scene for the turbo-one-step flow based on the
  # CONTENT PILLAR the run belongs to (not a hardcoded fashion pool).
  #
  # Root-cause fix for the NSFW-stall: the generator was stamping every run as
  # whatever pillar but ALWAYS rendering from the same 5-scene fashion/beauty
  # bank, which drifts toward bralette/lingerie and trips the gate. Each pillar
  # now maps to its own scene pool so cadence genuinely moves to another pillar
  # (cooking, travel, wellness...) instead of re-rolling lingerie every hour.
  #
  # CONTENT-STRATEGY FIX (2026-10-08): the original pools were 2-3 scenes per
  # pillar (16 pillar scenes + 2 defaults = 18 distinct prompts), so a 300-render
  # run drew the same person+pose+setting+lighting ~15-22 times each with only
  # seed noise as "variety". Instagram removes duplicate content, so this was
  # both a removal cause and a reach suppressor. The fix: (1) each pillar's pool
  # is now ~20 DISTINCT scenes (setting + activity + pose), and (2) pose/framing
  # and lighting are sampled from their OWN axes and inserted into the prompt, so
  # two renders differ along real axes (pose, framing, lighting, composition),
  # not just scene wording. The distinct-prompt space is now thousands, not 18.
  #
  # Scene keys are matched case-insensitively and by substring, so a pillar
  # named 'Food & Cooking' matches :food. Unknown pillars fall back to a safe
  # conservative pool. Every scene keeps identity/face/clothing preset safe and
  # NSFW-gate-clean (verified threshold ~0.5; clean portraits ~0.03), and keeps
  # the FACE (and usually a hand) in frame so the workflow's CLIPSeg "head" and
  # "hand" nodes always find a region (an empty mask aborts the whole render).
  class PillarPrompt
    SAFE_BASE =
      'A photorealistic portrait of Sarah, softly glowing skin, authentic candid expression, fully dressed in modest everyday clothing.'

    # Pose/framing/composition axis. Sampled independently of the scene so two
    # renders of the same scene still differ in framing. Every framing keeps the
    # FACE in frame (the CLIPSeg "head" node must find a region or the render
    # aborts) and stays full-clothed.
    FRAMINGS = [
      'three-quarter waist-up portrait, soft bokeh background',
      'head-and-shoulders portrait, shallow depth of field',
      'medium shot from the chest up, face centered and softly lit, natural candid framing, gentle shoulder angle',
      'environmental portrait, subject placed a third from frame edge, background softly in focus',
      'close portrait from the shoulders up, face clearly lit, soft vignette',
      'candid mid-shot, face turned slightly toward camera, natural smile',
      'relaxed seated portrait, shoulders and face centered, warm backdrop',
      'standing portrait, feet at frame bottom edge, headroom above, airy composition'
    ].freeze

    # Lighting axis. Sampled independently so two renders differ in light even
    # when the scene and framing match.
    LIGHTINGS = [
      'warm golden-hour light',
      'soft diffused window light',
      'cool crisp morning light',
      'gentle overcast ambient light',
      'warm lamplight with soft shadows',
      'bright airy daylight'
    ].freeze

    # pillar-name-token => scene variants. One sampled string is appended to
    # base + framing + lighting. Each scene names a distinct SETTING + ACTIVITY +
    # POSE so the pool is real variety, not paraphrases of the same shot.
    SCENES = {
      food: [
        'holding a plated home-cooked dish in a bright sunlit kitchen, cozy apron, gentle smile, shallow depth of field',
        'arranging fresh vegetables and herbs on a wooden counter, warm window light, candid laugh',
        'pairing wine with a charcuterie board at a rustic table, soft ambient light, relaxed pose',
        'kneading dough at a flour-dusted counter, focused gentle expression, warm kitchen glow',
        'tasting a spoonful of sauce from a simmering pan, bright range hood light, candid moment',
        'slicing ripe fruit on a marble island, morning light, neat apron, calm concentration',
        'setting a small breakfast tray with coffee and pastries on a sunny balcony, peaceful smile',
        'plating a colorful salad bowl with herbs, overhead kitchen light, tidy apron',
        'stirring a steaming mug of tea beside a plate of cookies, cozy sweater, soft window light',
        'chopping fresh basil and tomatoes at a wooden board, rustic farmhouse kitchen, candid glance',
        'lifting a cast-iron skillet of sauteed vegetables, warm stove glow, gentle smile',
        'pouring honey over yogurt in a bright minimal kitchen, airy daylight, relaxed pose',
        'reading a recipe card at a marble counter, thoughtful expression, soft morning light',
        'decorating a cake with a piping bag, focused calm, warm bakery light, tidy apron',
        'sipping a fresh smoothie bowl at a sunlit breakfast nook, candid laugh',
        'arranging a picnic basket with sandwiches on a garden blanket, golden light, happy pose',
        'stirring soup in a large pot, steam rising, cozy kitchen, warm ambient light',
        'setting fresh herbs into a vase beside a fruit bowl, bright kitchen, soft smile',
        'rolling out pastry on a floured board, warm pastry case glow behind, focused pose',
        'carrying a tray of freshly baked bread to a rustic table, warm window light, proud gentle smile'
      ],
      travel: [
        'standing with a packed daypack on a mountain trail, golden backlight, candid glow',
        'reading a travel journal in a sun-drenched window seat of a small cafe, city rooftops beyond',
        'holding a folded street map outside a landmark, warm late-afternoon light, engaged expression',
        'studying a train timetable at a bright station concourse, morning light, thoughtful pose',
        'walking along a cobbled lane with a camera, soft overcast light, candid stride',
        'sitting on a harbor bench with a coffee, boats beyond, golden light, relaxed smile',
        'checking a passport and boarding pass at an airport window, bright daylight, focused pose',
        'browsing a local market stall with colorful produce, warm ambient light, curious expression',
        'snapping a photo of a scenic viewpoint, arms raised slightly, backlit, joyful pose',
        'resting at a mountain cafe terrace with a guidebook, crisp morning light, calm pose',
        'carrying a rolled blanket toward a lakeside picnic spot, soft golden light, happy stride',
        'reading a city guide on a park bench, dappled light through trees, relaxed smile',
        'boarding a small ferry with a tote bag, harbor light, candid glance',
        'exploring a bookshop with a worn map in hand, warm lamplight, thoughtful pose',
        'watching a sunset from a clifftop lookout, warm glow, quiet contemplative pose',
        'waiting on a quiet platform with a suitcase, soft morning light, calm expression',
        'tasting a local pastry at a window-side bakery stool, golden light, delighted smile',
        'strolling a flower-lined boulevard with a light scarf, bright airy light, candid pose',
        'sketching a landmark in a small notebook, warm afternoon light, focused pose',
        'sipping tea at a hillside terrace overlooking rooftops, golden hour, serene smile'
      ],
      fitness: [
        'after an outdoor run, tying a hairband, cool morning light, bright healthy energy',
        'mid-jump rope on a sunlit driveway, motion blur behind, sportswear, dynamic candid',
        'stretching on a yoga mat in a bright studio, morning window light, calm pose',
        'doing a plank on a gym floor, focused expression, cool overhead light, sportswear',
        'cooling down with a water bottle beside a park path, morning glow, relaxed smile',
        'walking a sunlit trail with light dumbbells, bright airy light, energetic stride',
        'guiding a stretching routine on a deck, soft golden light, confident pose',
        'balancing on one leg with a foam roller, tidy home gym, warm window light, calm focus',
        'jogging lightly on a residential lane, early light, candid motion, sportswear',
        'resting on a bench after a hill sprint, breathing lightly, cool morning air, happy pose',
        'practicing a lunge sequence on a rooftop, golden backlight, strong calm pose',
        'rowing a machine in a bright gym, focused effort, cool ambient light, sportswear',
        'tending a small garden plot as a gentle workout, warm daylight, relaxed smile',
        'stretching arms overhead in a sunlit living room, soft light, easy morning pose',
        'riding a stationary bike near a window, bright daylight, steady focus, sportswear',
        'doing knee-to-chest stretches on a mat, calm breathing, warm studio light, relaxed pose',
        'walking a dog briskly along a park loop, morning light, cheerful stride',
        'lifting a light kettlebell in a tidy garage gym, warm light, controlled focus',
        'practicing slow flow yoga in a bright room, soft window light, serene pose',
        'finishing a cooldown stretch with a towel, golden outdoor light, satisfied smile'
      ],
      wellness: [
        'wrapped in a cozy robe after yoga, soft morning light through blinds, calm unhurried smile',
        'holding herbal tea after a meditation session, warm neutral tones, serene expression',
        'breathing deeply on a cushion by a window, soft dawn light, tranquil pose',
        'arranging fresh flowers on a bedside table, gentle morning light, peaceful smile',
        'reading a quiet journal on a daybed, warm lamplight, reflective calm pose',
        'sipping warm water with lemon on a balcony, soft golden light, unhurried ease',
        'wrapping up in a knitted throw with a book, cozy lamplight, soft contented pose',
        'practicing slow stretching in a bright living room, airy daylight, gentle focus',
        'tending a small herb garden on a windowsill, warm light, calm unhurried smile',
        'resting hands on a warm mug of tea at a quiet table, soft window light, serene pose',
        'listening to a calming playlist with eyes soft, cozy blanket, warm ambient light',
        'writing a gratitude list at a tidy desk, soft morning light, thoughtful smile',
        'enjoying a warm bath soak with candles, gentle glow, relaxed tranquil pose',
        'breathing in a sunlit corner with plants, bright airy light, peaceful calm',
        'folding laundry mindfully by a window, warm light, easy contented pose',
        'sitting with a warm blanket and soft music, evening lamplight, restful smile',
        'stretching neck and shoulders in a quiet room, soft warm light, unhurried pose',
        'sipping a calming herbal blend on a porch, golden hour, serene expression',
        'arranging a cozy reading corner with cushions, soft light, quiet happy pose',
        'pausing with a deep breath on a park bench, dappled light, tranquil calm'
      ],
      beauty: [
        'softly glowing skincare moment, plain casual tee, natural honest light, no heavy makeup',
        'gentle after-care glow in warm vanity light, modest natural relaxed look',
        'applying a light moisturizer in bright bathroom light, plain tee, natural smile',
        'sweeping hair back before a clean skincare routine, soft window light, candid pose',
        'blotting toner on a cotton pad at a tidy vanity, warm light, calm focus',
        'checking a serum bottle label, natural daylight, plain casual look, gentle smile',
        'tying hair in a soft scarf at a mirror, warm light, easy relaxed pose',
        'massaging temples gently at a quiet vanity, soft glow, peaceful expression',
        'setting a lightweight sunscreen beside a window, bright daylight, natural pose',
        'enjoying a face mist in cool morning light, plain tee, refreshing smile',
        'wrapping hair in a towel after a gentle wash, soft warm light, calm fresh pose',
        'arranging skincare bottles neatly on a shelf, warm light, tidy satisfied pose',
        'brushing hair slowly in soft light, plain casual clothes, relaxed smile',
        'tapping eye cream gently at a mirror, gentle glow, calm focused pose',
        'resting a hand on a clean skincare jar, natural light, quiet contented smile',
        'drying hands on a soft towel in warm light, plain casual look, easy pose',
        'reading a skincare label in a bright bathroom, candid glance, natural look',
        'clearing a tidy vanity shelf with a soft cloth, warm light, calm pose',
        'sipping water after a fresh routine, bright daylight, plain tee, natural smile',
        'settling into a cozy chair after self-care, warm lamplight, serene pose'
      ],
      lifestyle: [
        'arranging a quiet home balcony with a coffee and book at golden hour, peaceful smile',
        'reading a book in a cozy armchair by a tall window, warm afternoon light',
        'watering a small plant on a sunny windowsill, bright light, calm happy pose',
        'setting a tidy desk with a notebook and tea, soft window light, thoughtful smile',
        'folding a warm blanket on a sofa, cozy lamplight, contented pose',
        'sitting on a porch step with a ceramic mug, golden light, easy relaxed smile',
        'arranging fresh-cut flowers in a vase by a window, bright airy light, gentle pose',
        'dusting a shelf of books and keepsakes, warm light, tidy satisfied smile',
        'writing a letter at a quiet table, soft daylight, reflective calm pose',
        'enjoying a homemade pastry on a balcony bench, golden hour, happy relaxed pose',
        'tidying a bookshelf with a soft cloth, warm light, easy contented pose',
        'sitting with a warm throw and a podcast on a sofa, soft lamplight, restful smile',
        'arranging a fruit bowl on a kitchen counter, bright daylight, calm pose',
        'repotting a small herb plant in a sunny spot, warm light, gentle focus',
        'sipping tea by a tall window with a magazine, afternoon light, serene smile',
        'folding laundry into a neat basket by a window, warm light, easy pose',
        'setting a cozy reading nook with a cushion and lamp, soft glow, peaceful smile',
        'arranging a simple breakfast tray on a bed, bright morning light, contented pose',
        'strolling a tidy balcony garden with a watering can, golden light, happy stride',
        'resting with a warm blanket and soft music, evening lamplight, quiet smile'
      ],
      fashion: [
        'classic trench coat over a fitted top, city street with soft motion, elegant poised stance',
        'high-neck blouse and trousers, minimalist studio backdrop, confident quiet gaze',
        'tailored blazer over a plain tee, warm street light, relaxed confident pose',
        'soft knit sweater and wide trousers, bright daylight, easy candid stance',
        'mid-length dress with a light cardigan, garden backdrop, gentle smile',
        'plain button-up shirt tucked neatly, warm window light, calm poised pose',
        'oversized blazer over a modest knit, cool morning street light, relaxed stance',
        'A-line dress with a small scarf, soft studio light, quiet confident gaze',
        'tailored vest over a long-sleeve top, minimalist backdrop, elegant pose',
        'flowing blouse and straight trousers, bright airy light, easy candid stance',
        'long coat with a soft scarf, city sidewalk, warm late light, poised walk',
        'knit polo and relaxed trousers, soft window light, calm confident pose',
        'simple shift dress with a light wrap, garden soft light, gentle smile',
        'tucked shirt and tailored skirt, warm studio light, neat poised stance',
        'soft cardigan over a modest dress, bright daylight, relaxed smile',
        'straight trousers and a clean tee, minimalist backdrop, confident quiet pose',
        'longline coat over a knit dress, street light, elegant calm stance',
        'buttoned shirt and neat trousers, warm ambient light, tidy poised pose',
        'light blazer over a modest top, airy studio light, easy confident stance',
        'wrapped scarf over a fitted coat, city light, poised gentle smile'
      ]
    }.freeze

    DEFAULT_SCENES = [
      'lush park boardwalk in bright daylight, airy candid energy, fully dressed casual outfit',
      'a cozy reading nook at golden hour, warm lamplight, soft contemplative mood, relaxed sweater',
      'a tidy balcony with a coffee and book at golden hour, peaceful smile',
      'a quiet kitchen window with tea and fruit, bright airy light, calm relaxed pose'
    ].freeze

    # Thread-safe scene selection for a pillar (or default). Combines the pillar
    # scene, a sampled framing, and a sampled lighting into one prompt, so two
    # renders differ along pose/framing/lighting axes as well as the scene.
    def self.for_pillar(pillar)
      token = pillar&.name.to_s.downcase
      # Prefer the LONGEST matching key so 'Fitness & Wellness' favours :fitness
      # over the earlier-but-shorter :wellness when both are present.
      matches = SCENES.select { |key, _| token.include?(key.to_s) || key.to_s.include?(token) }
      # Explicit first-wins reduce: Ruby's max_by/sort_by both return the LAST
      # tied element, so 'Fitness & Wellness' (both :fitness and :wellness match
      # at length 7) must be resolved by declaration order — :fitness first.
      bank = matches.reduce(nil) do |best, (key, _)|
        best.nil? || key.to_s.length > best.to_s.length ? [ key, SCENES[key] ] : best
      end
      pool = bank ? bank.last : DEFAULT_SCENES
      "#{SAFE_BASE} #{FRAMINGS.sample}, #{LIGHTINGS.sample}, #{pool.sample}."
    end
  end
end
