-- ============================================================================
-- E2E-only helper: reset the n8n workflow metadata so that the Git JSON
-- (SOURCE OF TRUTH) can be re-imported as exactly ONE instance per workflow.
-- This is a DERIVED-artifact reset (n8n metadata DB); the geo_operator
-- business DB is NOT touched. Wraps all deletes in one transaction.
-- ============================================================================
BEGIN;
DELETE FROM execution_metadata;
DELETE FROM execution_data;
DELETE FROM execution_annotation_tags;
DELETE FROM execution_annotations;
DELETE FROM processed_data;
DELETE FROM workflow_publication_trigger_status;
DELETE FROM workflow_review_request_workflow;
DELETE FROM workflow_review_request_reviewers;
DELETE FROM workflow_review_request_authors;
DELETE FROM workflow_review_request;
DELETE FROM workflow_publish_history;
DELETE FROM workflow_published_version;
DELETE FROM workflow_builder_session;
DELETE FROM ai_builder_temporary_workflow;
DELETE FROM evaluation_config;
DELETE FROM evaluation_collection;
DELETE FROM chat_hub_messages;
DELETE FROM chat_hub_sessions;
DELETE FROM test_run;
DELETE FROM insights_metadata;
DELETE FROM workflow_dependency;
DELETE FROM shared_workflow;
DELETE FROM workflows_tags;
DELETE FROM webhook_entity;
DELETE FROM execution_entity;
-- workflow_entity references workflow_history(versionId); delete entity first.
DELETE FROM workflow_entity;
DELETE FROM workflow_history;
COMMIT;
