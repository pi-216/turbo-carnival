
> **Status:** HISTORICAL — early ideation
> A record of what happened, not instructions.
Here is the document describing the image generation and curation tool.

---

## 1. Concept: The What and Why

### What It Is

This tool is a **Curation and Workflow Management Hub** designed to sit between a user and a generative AI backend (like ComfyUI). It is not an image generator itself; it is an intelligent **job management system** that automates a multi-stage creative pipeline.

Its primary function is to manage the state of thousands of potential images, intelligently decide *which image to generate next*, and present the user with high-impact, "A vs. B" decisions to guide the system.

### Why It's Needed

The bottleneck in high-quality AI image generation is not *generation*; it's *curation and iteration*. A user needs to generate 30 "base" images, send 5 to a "face fix" workflow, send 3 of those to a "hand fix" workflow, and 2 of *those* to an "upscaler" to get one or two postable candidates.

This manual process is slow, tedious, and inefficient. This tool solves the problem by:
* **Automating the Funnel:** It automatically sends promising candidates from one step (e.g., "Base") to the next (e.g., "Face Fix").
* **Minimizing Time-to-Candidate:** It is designed to work autonomously, so a user can arrive in the morning and have several *fully-finished* candidates (from "Base" all the way to "Upscale") ready for review.
* **Optimizing GPU Usage:** It uses user feedback (via ELO ranking) to intelligently decide how to spend GPU cycles, prioritizing work on branches that show promise.
* **Providing Efficient Triage:** It replaces a folder full of files with a simple, rapid voting interface that feeds the algorithm.

---

## 2. The Data Model

The system is built on two core data models: `PipelineSteps` (the columns) and `ImageCandidates` (the nodes in the tree).

### The Columns: `PipelineStep`

This model defines the *stages* of the generative process. Each step is a "column" on the board.

* `id` (Integer): Primary key.
* `name` (String): A human-readable name (e.g., "Base Generation", "Face Fix", "Hand Fix", "Final Upscale").
* `order` (Integer): A number that defines the sequence. "Base" would be `1`, "Face" `2`, etc. This is crucial for the "right-to-left" logic.
* `comfy_workflow_json` (Text): The JSON of the ComfyUI workflow for this specific step.

### The Tree: `ImageCandidate`

This model represents a single, unique image. Every `ImageCandidate` is a node in a tree.

* `id` (Integer): Primary key.
* `pipeline_step_id` (Foreign Key): Links to the "column" this image belongs to (e.g., `pipeline_step: 3` "Hand Fix").
* `parent_id` (Foreign Key): Links to the `ImageCandidate` used as its source. This creates the tree. A "Base" image has `parent_id: null`.
* `image_path` (String): Filepath to the generated PNG.
* `elo_score` (Integer): The "rank" of this image, calculated via user votes. Defaults to a baseline (e.g., 1000). This score is used as the "ticket count" in the raffle.
* `status` (Enum): The state of the node.
    * **`active`:** Default state. The node is viable and can be voted on and have children.
    * **`rejected`:** The node has been "killed" by the user. The algorithm will *never* select this node as a parent, effectively pruning this entire branch from future growth.
* `child_count` (Integer): A cached count of how many direct children this node has.

### System Configuration

* **`N` (Max Children):** A global setting (e.g., `5`). No `ImageCandidate` node will ever be allowed to have more than `N` children.
* **`T` (Target Leaf Nodes):** A global setting (e.g., `10`). The "deficit" the system autonomously tries to fill in the *right-most column*.

---

## 3. The Job Algorithm

This is the core logic that deterministically decides the *single next job* to send to ComfyUI. This algorithm runs in a loop and is based *only* on the current database state.

It is a single, state-agnostic process that finds the highest-priority "parent" node that needs a "child" generated.

### "Next Job" Algorithm:

1.  **Find Eligible Parents:** The system queries the `ImageCandidate` table for all nodes that meet these criteria:
    * `status` is `'active'` (i.e., not `rejected`).
    * `child_count` is LESS THAN `N`.
    * The node's `PipelineStep` is *not* the final step in the pipeline.

2.  **Prioritize by Column (Right-to-Left):**
    * The system sorts this list of eligible parents **descending by `PipelineStep.order`**.
    * This ensures the system *always* prioritizes finishing work. A "Hand Fix" job (Step 3) will *always* be selected over a "Base Generation" job (Step 1), regardless of ELO score.

3.  **Isolate the Top Priority Column:**
    * The system now has a list of *all* eligible parent nodes from the highest-priority column (e.g., all "Face Fix" nodes that are active and have < 5 children).

4.  **Perform the ELO Raffle (Probabilistic Selection):**
    * The system does *not* just pick the highest ELO node. It uses a **weighted random selection ("raffle")** to balance exploitation (working on the best) and exploration (giving long-shots a chance).
    * **a. Calculate Total Weight:** Sum the `elo_score` of all nodes in this top-priority list.
    * **b. Pick Winner:** Perform a weighted random selection where each node's `elo_score` is its number of "tickets" in the raffle.
    * The winning node is the **chosen parent**. The system creates a new job using this parent's image and the *next* step's workflow.

5.  **Handle Autonomous "Deficit" Mode:**
    * What if the query from Step 1 returns *nothing*? (e.g., all branches are full).
    * The system checks the right-most column ("Final Upscale"). If the count of `active` nodes is LESS THAN `T` (Target Leaf Nodes), it is in a "deficit."
    * It will automatically trigger a new **"Base Generation" job** (a `parent_id: null` job) to start a new tree, which will then be autonomously grown using the same logic.

---

## 4. The Voting Interface

The UI is the user's "control panel" for feeding the algorithm. The primary interface is a rapid, "A vs. B" ELO ranking system.

### "Triage-Right" Workflow

* The user is first presented with two images (`Candidate A` vs. `Candidate B`) to compare.
* The system prioritizes showing images from the **right-most column** ("Final Upscale") that the user has not yet voted on.
* The user has two primary actions: **Vote** or **Kill**.

**Action 1: Vote**
* The user clicks the image they think is better.
* **Backend:** The ELO scores for both images are recalculated and saved to the database.
* **UI:** The next pair of images is immediately loaded for review. This action is rapid and intended to be done many times.

**Action 2: Kill (The "Kill-Left" Workflow)**
* The user sees a "no-go" candidate (`Candidate B`) and clicks "Kill."
* The UI does *not* just delete it. It assumes this `Final` image failed for a *reason*, and it helps the user find the root.
* **UI Navigates Left:** The view instantly changes, presenting the *parent* of the image (`Hands-B`) next to one of its *siblings* (`Hands-C`).
* **The New Question:** The UI is now asking, "Was the *Hand Fix* the problem, or was it just this one `Final` upscale?"
* The user can now vote or kill at *this* level. If they "Kill" `Hands-B`, the UI navigates left *again* to the "Face Fix" level.
* **The Goal:** The user continues this "kill-left" navigation until they find the *true* root of the bad image (e.g., the "Base" image had a bad pose).
* **Final "Kill" Action:** The user clicks "Kill" on `Base-B`.
* **Backend:** The `status` of `Base-B` is set to `'rejected'`.
* **Result:** The algorithm (from Section 3) will *instantly* and *permanently* stop all future work on this entire branch, as `Base-B` is no longer an eligible parent. This is far more efficient than just rejecting the final leaf image.
