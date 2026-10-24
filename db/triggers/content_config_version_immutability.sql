-- Append-only guard for the content config version (#40, PRD 0002 / plan item W1.2).
--
-- WHY THIS EXISTS
-- A version's identity IS its content: `Attribution::ContentConfigVersion` derives its
-- digest from the pinned axes, so a changed pin is a DIFFERENT version. Editing a version in
-- place destroys the attribution of every render that referenced it, retroactively -- the
-- same failure the DB-only workflow column had (#40's red line).
--
-- The other two layers of that guarantee live in the model (`#readonly?` refuses every
-- ActiveRecord write path; the digest is derived, never authored). Neither can see
-- `update_all`, `delete_all`, or a future migration writing raw SQL, so the last layer has
-- to be the database's.
--
-- WHY THIS FILE IS SEPARATE FROM THE MIGRATION
-- Rails' schema format in this repo is `:ruby`, and `db/schema.rb` cannot carry a trigger.
-- A trigger created only by the migration would therefore be ABSENT from every database
-- built by `db:test:prepare` -- including CI's -- and the spec proving it bites would pass
-- against a guard that was not there. So the SQL lives in one file and is applied by two
-- callers: the migration that creates the tables, and `spec/support/db_triggers.rb`, which
-- applies it to the test database before the suite runs.
--
-- Idempotent by construction (CREATE OR REPLACE + DROP TRIGGER IF EXISTS), so re-applying it
-- is safe. Child rows are guarded too: a mutable pin contradicts the digest that names it,
-- which is an edit wearing the costume of a child row.

CREATE OR REPLACE FUNCTION content_config_versions_are_append_only() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'content config versions are append-only: % on % refused (change the config by writing a NEW version, never by editing this one)', TG_OP, TG_TABLE_NAME
    USING ERRCODE = 'restrict_violation';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS content_config_versions_no_mutation ON content_config_versions;
CREATE TRIGGER content_config_versions_no_mutation
  BEFORE UPDATE OR DELETE ON content_config_versions
  FOR EACH ROW EXECUTE FUNCTION content_config_versions_are_append_only();

DROP TRIGGER IF EXISTS content_config_version_prompt_parts_no_mutation ON content_config_version_prompt_parts;
CREATE TRIGGER content_config_version_prompt_parts_no_mutation
  BEFORE UPDATE OR DELETE ON content_config_version_prompt_parts
  FOR EACH ROW EXECUTE FUNCTION content_config_versions_are_append_only();

DROP TRIGGER IF EXISTS content_config_version_loras_no_mutation ON content_config_version_loras;
CREATE TRIGGER content_config_version_loras_no_mutation
  BEFORE UPDATE OR DELETE ON content_config_version_loras
  FOR EACH ROW EXECUTE FUNCTION content_config_versions_are_append_only();
