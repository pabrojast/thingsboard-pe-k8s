--
-- ThingsBoard PE Schema Migration Recovery Script
-- 
-- This script fixes a PE database stuck at schema_version 3007000 (3.7.0)
-- by applying all missing schema changes up to 3.9.0 level.
-- After running this, the PE upgrade scripts (4.0.0PE → 4.3.0.1PE) can run normally.
--
-- IMPORTANT: This is tailored for a PE database that already has PE-specific tables
-- (mobile_app_bundle, qr_code_settings, domain_oauth2_client, etc.)
-- but is missing CE schema changes from 3.8.0 and 3.9.0.
--
-- Run this AFTER taking a full database backup!
--

BEGIN;

-- =====================================================
-- PART 1: CE 3.7.0 → 3.8.0 schema changes
-- (from upgrade/3.7.0/schema_update.sql)
-- =====================================================

-- UPDATE RESOURCE SUB TYPE
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_name = 'resource' AND column_name = 'resource_sub_type'
    ) THEN
        ALTER TABLE resource ADD COLUMN resource_sub_type varchar(32);
        UPDATE resource SET resource_sub_type = 'IMAGE' WHERE resource_type = 'IMAGE';
    END IF;
END;
$$;

-- UPDATE WIDGETS BUNDLE - add scada column
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_name = 'widgets_bundle' AND column_name = 'scada'
    ) THEN
        ALTER TABLE widgets_bundle ADD COLUMN scada boolean NOT NULL DEFAULT false;
    END IF;
END;
$$;

-- UPDATE WIDGET TYPE - add scada column
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_name = 'widget_type' AND column_name = 'scada'
    ) THEN
        ALTER TABLE widget_type ADD COLUMN scada boolean NOT NULL DEFAULT false;
    END IF;
END;
$$;

-- KV VERSIONING
CREATE SEQUENCE IF NOT EXISTS attribute_kv_version_seq cache 1;
CREATE SEQUENCE IF NOT EXISTS ts_kv_latest_version_seq cache 1;
ALTER TABLE attribute_kv ADD COLUMN IF NOT EXISTS version bigint default 0;
ALTER TABLE ts_kv_latest ADD COLUMN IF NOT EXISTS version bigint default 0;

-- RELATION VERSIONING
CREATE SEQUENCE IF NOT EXISTS relation_version_seq cache 1;
ALTER TABLE relation ADD COLUMN IF NOT EXISTS version bigint default 0;

-- ENTITIES VERSIONING
ALTER TABLE device ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE device_profile ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE device_credentials ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE asset ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE asset_profile ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE entity_view ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE tb_user ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE customer ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE edge ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE rule_chain ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE dashboard ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE widget_type ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE widgets_bundle ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;
ALTER TABLE tenant ADD COLUMN IF NOT EXISTS version BIGINT DEFAULT 1;

-- OAUTH2 UPDATE (PE-safe version: skip migrations that reference oauth2_params_id)
-- domain: add missing columns
ALTER TABLE domain ADD COLUMN IF NOT EXISTS oauth2_enabled boolean;
ALTER TABLE domain ADD COLUMN IF NOT EXISTS edge_enabled boolean;
ALTER TABLE domain ADD COLUMN IF NOT EXISTS tenant_id uuid DEFAULT '13814000-1dd2-11b2-8080-808080808080';
ALTER TABLE domain DROP COLUMN IF EXISTS domain_scheme;

-- rename domain_name to name if needed
DO $$
BEGIN
    IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='domain' AND column_name='domain_name') THEN
        ALTER TABLE domain RENAME COLUMN domain_name TO name;
    END IF;
END;
$$;

-- delete duplicated domains
DELETE FROM domain d1 USING (
    SELECT MIN(ctid) as ctid, name
    FROM domain
    GROUP BY name HAVING COUNT(*) > 1
) d2 WHERE d1.name = d2.name AND d1.ctid <> d2.ctid;

-- mobile_app: add missing columns (PE already has platform_type, status, etc.)
ALTER TABLE mobile_app ADD COLUMN IF NOT EXISTS oauth2_enabled boolean;

-- oauth2_client: add missing columns
ALTER TABLE oauth2_client ADD COLUMN IF NOT EXISTS tenant_id uuid DEFAULT '13814000-1dd2-11b2-8080-808080808080';
ALTER TABLE oauth2_client ADD COLUMN IF NOT EXISTS title varchar(100);
UPDATE oauth2_client SET title = additional_info::jsonb->>'providerName' 
    WHERE additional_info IS NOT NULL AND title IS NULL;

-- domain_oauth2_client already exists in PE, skip creation

-- PE-specific: Drop oauth2_params_id from tables that still have it, and clean up
-- (The PE upgrade should have done this, but it was skipped)
DO $$
BEGIN
    -- Drop oauth2_params_id from domain
    IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='domain' AND column_name='oauth2_params_id') THEN
        ALTER TABLE domain DROP COLUMN oauth2_params_id;
    END IF;
    -- Drop oauth2_params_id from oauth2_client
    IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='oauth2_client' AND column_name='oauth2_params_id') THEN
        ALTER TABLE oauth2_client DROP COLUMN oauth2_params_id;
    END IF;
END;
$$;

-- Add unique constraints if missing
DO $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conname = 'domain_unq_key' OR conname = 'domain_name_key') THEN
        ALTER TABLE domain ADD CONSTRAINT domain_name_key UNIQUE (name);
    END IF;
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

-- USER CREDENTIALS UPDATE
ALTER TABLE user_credentials ADD COLUMN IF NOT EXISTS activate_token_exp_time BIGINT;
UPDATE user_credentials SET activate_token_exp_time = cast(extract(EPOCH FROM NOW()) * 1000 AS BIGINT) + 86400000
    WHERE activate_token IS NOT NULL AND activate_token_exp_time IS NULL;

ALTER TABLE user_credentials ADD COLUMN IF NOT EXISTS reset_token_exp_time BIGINT;
UPDATE user_credentials SET reset_token_exp_time = cast(extract(EPOCH FROM NOW()) * 1000 AS BIGINT) + 86400000
    WHERE reset_token IS NOT NULL AND reset_token_exp_time IS NULL;

-- Update device profile rule nodes (from Java code in 3.8.0 upgrade)
UPDATE rule_node SET
    configuration = CASE
        WHEN (configuration::jsonb ->> 'persistAlarmRulesState') = 'false'
        THEN (configuration::jsonb || '{"fetchAlarmRulesStateOnStart": "false"}'::jsonb)::varchar
        ELSE configuration
    END,
    configuration_version = 1
WHERE type = 'org.thingsboard.rule.engine.profile.TbDeviceProfileNode'
AND configuration_version < 1;

-- Update schema version to 3.8.0
UPDATE tb_schema_settings SET schema_version = 3008000;


-- =====================================================
-- PART 2: CE 3.8.0 → 3.9.0 schema changes
-- (from upgrade/basic/schema_update.sql in v3.9 tag)
-- =====================================================

-- USER CREDENTIALS - login tracking
ALTER TABLE user_credentials ADD COLUMN IF NOT EXISTS last_login_ts BIGINT;
UPDATE user_credentials c SET last_login_ts = (SELECT (additional_info::json ->> 'lastLoginTs')::bigint FROM tb_user u WHERE u.id = c.user_id)
    WHERE last_login_ts IS NULL;

ALTER TABLE user_credentials ADD COLUMN IF NOT EXISTS failed_login_attempts INT;
UPDATE user_credentials c SET failed_login_attempts = (SELECT (additional_info::json ->> 'failedLoginAttempts')::int FROM tb_user u WHERE u.id = c.user_id)
    WHERE failed_login_attempts IS NULL;

UPDATE tb_user SET additional_info = (additional_info::jsonb - 'lastLoginTs' - 'failedLoginAttempts' - 'userCredentialsEnabled')::text
    WHERE additional_info IS NOT NULL AND additional_info != 'null' AND jsonb_typeof(additional_info::jsonb) = 'object';

-- RULE NODE DEBUG MODE → DEBUG SETTINGS
ALTER TABLE rule_node ADD COLUMN IF NOT EXISTS debug_settings varchar(1024) DEFAULT null;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'rule_node' AND column_name = 'debug_mode') THEN
        UPDATE rule_node SET debug_settings = '{"failuresEnabled": true, "allEnabledUntil": ' || cast((extract(epoch from now()) + 900) * 1000 as bigint) || '}' WHERE debug_mode = true;
        ALTER TABLE rule_node DROP COLUMN debug_mode;
    END IF;
END;
$$;

-- MOBILE APP BUNDLE - already exists in PE, add missing columns
ALTER TABLE mobile_app_bundle ADD COLUMN IF NOT EXISTS oauth2_enabled boolean;

-- mobile_app_bundle_oauth2_client already exists in PE

-- mobile_app: oauth2_enabled already added above, ensure constraint
DO $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conname = 'mobile_app_pkg_name_platform_unq_key') THEN
        ALTER TABLE mobile_app ADD CONSTRAINT mobile_app_pkg_name_platform_unq_key UNIQUE (pkg_name, platform_type);
    END IF;
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

-- QR_CODE_SETTINGS already exists in PE
ALTER TABLE qr_code_settings ADD COLUMN IF NOT EXISTS mobile_app_bundle_id uuid;
ALTER TABLE qr_code_settings ADD COLUMN IF NOT EXISTS android_enabled boolean;
ALTER TABLE qr_code_settings ADD COLUMN IF NOT EXISTS ios_enabled boolean;

-- Drop old oauth2_enabled from mobile_app (moved to bundle)
ALTER TABLE mobile_app DROP COLUMN IF EXISTS oauth2_enabled;

-- domain constraint update
DO $$
BEGIN
    ALTER TABLE domain DROP CONSTRAINT IF EXISTS domain_unq_key;
    IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conname = 'domain_name_key') THEN
        ALTER TABLE domain ADD CONSTRAINT domain_name_key UNIQUE (name);
    END IF;
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

-- UPDATE RESOURCE JS_MODULE SUB TYPE
UPDATE resource SET resource_sub_type = 'EXTENSION' WHERE resource_type = 'JS_MODULE' AND resource_sub_type IS NULL;

-- Update schema version to 3.9.0 (3009000)
UPDATE tb_schema_settings SET schema_version = 3009000;


-- =====================================================
-- PART 3: Add 'product' column to tb_schema_settings
-- (required by PE 4.x upgrade scripts)
-- =====================================================

ALTER TABLE tb_schema_settings ADD COLUMN IF NOT EXISTS product varchar(64);


-- =====================================================
-- PART 4: Drop deprecated tables
-- =====================================================

DROP TABLE IF EXISTS oauth2_params CASCADE;
DROP TABLE IF EXISTS oauth2_client_registration_info CASCADE;
DROP TABLE IF EXISTS oauth2_client_registration CASCADE;
DROP TABLE IF EXISTS oauth2_client_registration_template CASCADE;


COMMIT;

-- Verify final state
SELECT 'Schema version: ' || schema_version FROM tb_schema_settings;
SELECT 'Product: ' || COALESCE(product, 'NULL') FROM tb_schema_settings;
