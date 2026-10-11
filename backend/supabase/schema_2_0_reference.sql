-- Fresh isolated Supabase/Postgres 15+ prototype schema.
-- NOT an automatic migration of unknown existing profiles/sessions/stories.
-- Review on disposable local Supabase before any production deployment.
begin;
create schema if not exists candid_memory;
create type candid_memory.visibility_t as enum ('private','team');
create type candid_memory.source_t as enum ('user','device','ai');
create type candid_memory.trust_t as enum ('L1_evidence','L2_inferred','L3_confirmed');

create table candid_memory.profiles (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint profiles_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint profiles_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint profiles_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 target_roles jsonb not null default '[]', timeline jsonb, concerns jsonb not null default '[]', preferences jsonb not null default '{"audio_retention_days":90}', cross_border_consent_at timestamptz
);
alter table candid_memory.profiles enable row level security;
create policy profiles_owner_rw on candid_memory.profiles for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index profiles_owner_created on candid_memory.profiles(owner_id,created_at desc,id desc);

create table candid_memory.occasions (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint occasions_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint occasions_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint occasions_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 client_request_id uuid not null, scenario text not null check(scenario in ('interview','pitch','academic','sales')), title text not null, counterpart jsonb, target_date timestamptz, status text not null default 'active', template_version text not null, fields jsonb not null default '{}', created_from_text text, unique(owner_id,client_request_id)
);
alter table candid_memory.occasions enable row level security;
create policy occasions_owner_rw on candid_memory.occasions for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index occasions_owner_created on candid_memory.occasions(owner_id,created_at desc,id desc);

create table candid_memory.documents (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint documents_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint documents_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint documents_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 occasion_id uuid, kind text not null, storage_path text not null, sha256 text not null, parsed_text text, unique(owner_id,sha256)
);
alter table candid_memory.documents enable row level security;
create policy documents_owner_rw on candid_memory.documents for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index documents_owner_created on candid_memory.documents(owner_id,created_at desc,id desc);

create table candid_memory.experiences (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint experiences_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint experiences_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint experiences_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 title text not null, org text, start_on date, end_on date, bullets text[] not null default '{}', document_id uuid, status text not null default 'draft', version int not null default 1
);
alter table candid_memory.experiences enable row level security;
create policy experiences_owner_rw on candid_memory.experiences for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index experiences_owner_created on candid_memory.experiences(owner_id,created_at desc,id desc);

alter table candid_memory.experiences add constraint experiences_confirmed_is_l3 check(status!='confirmed' or trust='L3_confirmed');
create table candid_memory.assets (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint assets_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint assets_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint assets_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 kind text not null check(kind in ('story','qa_answer','objection_answer','phrasing','example')), scenario text, title text not null, body jsonb not null, tags text[] not null default '{}', competencies text[] not null default '{}', status text not null default 'draft' check(status in ('draft','confirmed','archived')), est_talk_seconds int, use_count int not null default 0, last_used_at timestamptz, version int not null default 1, source_session_id uuid, source_unit_id uuid, parent_asset_id uuid
);
alter table candid_memory.assets enable row level security;
create policy assets_owner_rw on candid_memory.assets for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index assets_owner_created on candid_memory.assets(owner_id,created_at desc,id desc);

alter table candid_memory.assets add constraint assets_confirmed_is_l3 check(status!='confirmed' or trust='L3_confirmed');
create table candid_memory.asset_revisions (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint asset_revisions_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint asset_revisions_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint asset_revisions_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 asset_id uuid not null, version int not null, body jsonb not null, edited_by uuid, unique(owner_id,asset_id,version)
);
alter table candid_memory.asset_revisions enable row level security;
create policy asset_revisions_owner_rw on candid_memory.asset_revisions for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index asset_revisions_owner_created on candid_memory.asset_revisions(owner_id,created_at desc,id desc);

create table candid_memory.question_bank (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint question_bank_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint question_bank_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint question_bank_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 scenario text not null, question_essence text not null, essence_hash text not null, question_type text, competency text, seen_count int not null default 1, first_seen_session_id uuid, last_seen_at timestamptz, unique(owner_id,scenario,essence_hash)
);
alter table candid_memory.question_bank enable row level security;
create policy question_bank_owner_rw on candid_memory.question_bank for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index question_bank_owner_created on candid_memory.question_bank(owner_id,created_at desc,id desc);

create table candid_memory.baselines (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint baselines_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint baselines_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint baselines_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 scope text not null check(scope in ('delivery','content')), scenario text, metric_key text not null, value double precision, n_sessions int not null, window_size int not null default 5, computed_at timestamptz, check((scope='delivery' and scenario is null) or (scope='content' and scenario is not null)), unique nulls not distinct(owner_id,scope,scenario,metric_key,rubric_version)
);
alter table candid_memory.baselines enable row level security;
create policy baselines_owner_rw on candid_memory.baselines for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index baselines_owner_created on candid_memory.baselines(owner_id,created_at desc,id desc);

create table candid_memory.weaknesses (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint weaknesses_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint weaknesses_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint weaknesses_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 scenario text not null, dimension text not null, description text not null, state text not null check(state in ('observed','open','improving','resolved','disputed')), hit_count int not null default 1, consecutive_pass int not null default 0, first_session_id uuid, last_session_id uuid, user_disagrees boolean not null default false, unique(owner_id,scenario,dimension,rubric_version)
);
alter table candid_memory.weaknesses enable row level security;
create policy weaknesses_owner_rw on candid_memory.weaknesses for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index weaknesses_owner_created on candid_memory.weaknesses(owner_id,created_at desc,id desc);

create table candid_memory.occasion_artifacts (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint occasion_artifacts_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint occasion_artifacts_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint occasion_artifacts_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 occasion_id uuid not null, kind text not null, content jsonb not null, sources jsonb not null default '[]', expires_at timestamptz, template_version text, unique(owner_id,occasion_id,kind,template_version)
);
alter table candid_memory.occasion_artifacts enable row level security;
create policy occasion_artifacts_owner_rw on candid_memory.occasion_artifacts for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index occasion_artifacts_owner_created on candid_memory.occasion_artifacts(owner_id,created_at desc,id desc);

create table candid_memory.audiences (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint audiences_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint audiences_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint audiences_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 occasion_id uuid not null, role_key text not null, label text not null, agent_config_version text not null, unique(owner_id,occasion_id,role_key)
);
alter table candid_memory.audiences enable row level security;
create policy audiences_owner_rw on candid_memory.audiences for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index audiences_owner_created on candid_memory.audiences(owner_id,created_at desc,id desc);

create table candid_memory.script_versions (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint script_versions_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint script_versions_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint script_versions_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 occasion_id uuid not null, version_no int not null, content text not null, derived_from_session_id uuid, status text not null default 'draft', unique(owner_id,occasion_id,version_no)
);
alter table candid_memory.script_versions enable row level security;
create policy script_versions_owner_rw on candid_memory.script_versions for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index script_versions_owner_created on candid_memory.script_versions(owner_id,created_at desc,id desc);

alter table candid_memory.script_versions add constraint script_versions_confirmed_is_l3 check(status!='confirmed' or trust='L3_confirmed');
create table candid_memory.outcomes (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint outcomes_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint outcomes_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint outcomes_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 occasion_id uuid not null, session_id uuid, result text not null, note text, reported_at timestamptz not null default now(), unique nulls not distinct(owner_id,occasion_id,session_id)
);
alter table candid_memory.outcomes enable row level security;
create policy outcomes_owner_rw on candid_memory.outcomes for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index outcomes_owner_created on candid_memory.outcomes(owner_id,created_at desc,id desc);

create table candid_memory.sessions (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint sessions_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint sessions_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint sessions_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 occasion_id uuid, client_request_id uuid not null, scenario text not null, kind text not null check(kind in ('practice','live','oral_debrief')), audience_id uuid, device_id text, started_at timestamptz not null default now(), duration_ms bigint not null default 0, consent text not null check(consent in ('yes','no','unknown')), consent_at timestamptz, consent_ack_text_version text, retention_days int not null default 90 check(retention_days in (0,7,30,90,180)), purge_at timestamptz not null, audio_purged_at timestamptz, pipeline_status text not null default 'queued', legacy_analysis jsonb, unique(owner_id,client_request_id), check(kind!='practice' or consent='yes'), check(kind!='live' or consent!='yes' or consent_ack_text_version is not null)
);
alter table candid_memory.sessions enable row level security;
create policy sessions_owner_rw on candid_memory.sessions for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index sessions_owner_created on candid_memory.sessions(owner_id,created_at desc,id desc);

create table candid_memory.session_media (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint session_media_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint session_media_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint session_media_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 session_id uuid not null, storage_path text not null, mime text not null, bytes bigint not null, sha256 text not null, unique(owner_id,session_id,sha256)
);
alter table candid_memory.session_media enable row level security;
create policy session_media_owner_rw on candid_memory.session_media for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index session_media_owner_created on candid_memory.session_media(owner_id,created_at desc,id desc);

create table candid_memory.marks (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint marks_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint marks_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint marks_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 session_id uuid not null, t_ms bigint not null check(t_ms>=0), user_label text not null default 'unlabeled', unique(owner_id,session_id,t_ms)
);
alter table candid_memory.marks enable row level security;
create policy marks_owner_rw on candid_memory.marks for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index marks_owner_created on candid_memory.marks(owner_id,created_at desc,id desc);

create table candid_memory.transcript_segments (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint transcript_segments_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint transcript_segments_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint transcript_segments_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 session_id uuid not null, speaker text not null check(speaker in ('self','other','unknown')), start_ms bigint not null, end_ms bigint not null, text text not null, words jsonb not null default '[]', asr_producer text not null, check(0<=start_ms and start_ms<end_ms)
);
alter table candid_memory.transcript_segments enable row level security;
create policy transcript_segments_owner_rw on candid_memory.transcript_segments for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index transcript_segments_owner_created on candid_memory.transcript_segments(owner_id,created_at desc,id desc);

create table candid_memory.qa_units (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint qa_units_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint qa_units_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint qa_units_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 session_id uuid not null, mode text not null, question_essence text, question_type text, q_start_ms bigint, q_end_ms bigint, a_start_ms bigint not null, a_end_ms bigint not null
);
alter table candid_memory.qa_units enable row level security;
create policy qa_units_owner_rw on candid_memory.qa_units for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index qa_units_owner_created on candid_memory.qa_units(owner_id,created_at desc,id desc);

create table candid_memory.metrics (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint metrics_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint metrics_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint metrics_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 session_id uuid not null, unit_id uuid, metric_key text not null, value double precision, unique nulls not distinct(owner_id,session_id,unit_id,metric_key,rubric_version)
);
alter table candid_memory.metrics enable row level security;
create policy metrics_owner_rw on candid_memory.metrics for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index metrics_owner_created on candid_memory.metrics(owner_id,created_at desc,id desc);

create table candid_memory.diagnoses (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint diagnoses_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint diagnoses_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint diagnoses_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 session_id uuid not null, unit_id uuid, audience_role text, dimension text not null, score double precision, finding text not null, suggestion text, check(jsonb_array_length(evidence_refs)>0)
);
alter table candid_memory.diagnoses enable row level security;
create policy diagnoses_owner_rw on candid_memory.diagnoses for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index diagnoses_owner_created on candid_memory.diagnoses(owner_id,created_at desc,id desc);

create table candid_memory.diagnosis_feedback (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 visibility candid_memory.visibility_t not null default 'private' check(visibility='private'),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 source candid_memory.source_t not null, trust candid_memory.trust_t not null,
 producer text, rubric_version text, evidence_refs jsonb not null default '[]',
 confirmed_by uuid, confirmed_at timestamptz,
 constraint diagnosis_feedback_producer check(source!='ai' or (producer is not null and length(producer)>0)),
 constraint diagnosis_feedback_l2_traceable check(trust!='L2_inferred' or (rubric_version is not null and producer is not null)),
 constraint diagnosis_feedback_l3_human check(trust!='L3_confirmed' or (source='user' and confirmed_by=owner_id and confirmed_at is not null)),
 unique(owner_id,id),
 diagnosis_id uuid not null, verdict text not null check(verdict in ('agree','disagree','adopted')), note text, unique(owner_id,diagnosis_id)
);
alter table candid_memory.diagnosis_feedback enable row level security;
create policy diagnosis_feedback_owner_rw on candid_memory.diagnosis_feedback for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid() and visibility='private');
create index diagnosis_feedback_owner_created on candid_memory.diagnosis_feedback(owner_id,created_at desc,id desc);


create function candid_memory.guard_write() returns trigger language plpgsql set search_path=pg_catalog,candid_memory as $$
begin
 if NEW.trust='L3_confirmed' then
   if auth.uid() is null or auth.role()!='authenticated' or NEW.confirmed_by!=auth.uid() or NEW.owner_id!=auth.uid() then
     raise exception 'L3_NEEDS_HUMAN';
   end if;
 end if;
 if TG_OP='UPDATE' and NEW.owner_id!=OLD.owner_id then raise exception 'OWNER_IMMUTABLE'; end if;
 NEW.updated_at=now(); return NEW;
end $$;
create function candid_memory.guard_l1() returns trigger language plpgsql set search_path=pg_catalog,candid_memory as $$
begin raise exception 'L1_IMMUTABLE'; end $$;
create function candid_memory.guard_diagnosis() returns trigger language plpgsql set search_path=pg_catalog,candid_memory as $$
declare ref jsonb;
begin
 if jsonb_array_length(NEW.evidence_refs)=0 then raise exception 'EVIDENCE_MISSING'; end if;
 for ref in select value from jsonb_array_elements(NEW.evidence_refs) loop
   if not exists(select 1 from candid_memory.transcript_segments t
     where t.owner_id=NEW.owner_id and t.session_id=(ref->>'session_id')::uuid
       and t.session_id=NEW.session_id and t.speaker='self'
       and t.start_ms <= (ref->>'start_ms')::bigint and t.end_ms >= (ref->>'end_ms')::bigint
       and (ref->>'start_ms')::bigint < (ref->>'end_ms')::bigint)
   then raise exception 'EVIDENCE_INVALID'; end if;
 end loop;
 return NEW;
end $$;
create trigger diagnoses_evidence before insert or update on candid_memory.diagnoses for each row execute function candid_memory.guard_diagnosis();

create trigger profiles_write before insert or update on candid_memory.profiles for each row execute function candid_memory.guard_write();
create trigger occasions_write before insert or update on candid_memory.occasions for each row execute function candid_memory.guard_write();
create trigger documents_write before insert or update on candid_memory.documents for each row execute function candid_memory.guard_write();
create trigger documents_l1 before update on candid_memory.documents for each row execute function candid_memory.guard_l1();
alter table candid_memory.documents add foreign key(owner_id,occasion_id) references candid_memory.occasions(owner_id,id) on delete cascade;
create trigger experiences_write before insert or update on candid_memory.experiences for each row execute function candid_memory.guard_write();
alter table candid_memory.experiences add foreign key(owner_id,document_id) references candid_memory.documents(owner_id,id) on delete cascade;
create trigger assets_write before insert or update on candid_memory.assets for each row execute function candid_memory.guard_write();
alter table candid_memory.assets add foreign key(owner_id,source_session_id) references candid_memory.sessions(owner_id,id) on delete cascade;
create trigger asset_revisions_write before insert or update on candid_memory.asset_revisions for each row execute function candid_memory.guard_write();
alter table candid_memory.asset_revisions add foreign key(owner_id,asset_id) references candid_memory.assets(owner_id,id) on delete cascade;
create trigger question_bank_write before insert or update on candid_memory.question_bank for each row execute function candid_memory.guard_write();
create trigger baselines_write before insert or update on candid_memory.baselines for each row execute function candid_memory.guard_write();
create trigger weaknesses_write before insert or update on candid_memory.weaknesses for each row execute function candid_memory.guard_write();
create trigger occasion_artifacts_write before insert or update on candid_memory.occasion_artifacts for each row execute function candid_memory.guard_write();
alter table candid_memory.occasion_artifacts add foreign key(owner_id,occasion_id) references candid_memory.occasions(owner_id,id) on delete cascade;
create trigger audiences_write before insert or update on candid_memory.audiences for each row execute function candid_memory.guard_write();
alter table candid_memory.audiences add foreign key(owner_id,occasion_id) references candid_memory.occasions(owner_id,id) on delete cascade;
create trigger script_versions_write before insert or update on candid_memory.script_versions for each row execute function candid_memory.guard_write();
alter table candid_memory.script_versions add foreign key(owner_id,occasion_id) references candid_memory.occasions(owner_id,id) on delete cascade;
create trigger outcomes_write before insert or update on candid_memory.outcomes for each row execute function candid_memory.guard_write();
alter table candid_memory.outcomes add foreign key(owner_id,occasion_id) references candid_memory.occasions(owner_id,id) on delete cascade;
alter table candid_memory.outcomes add foreign key(owner_id,session_id) references candid_memory.sessions(owner_id,id) on delete cascade;
create trigger sessions_write before insert or update on candid_memory.sessions for each row execute function candid_memory.guard_write();
alter table candid_memory.sessions add foreign key(owner_id,occasion_id) references candid_memory.occasions(owner_id,id) on delete cascade;
alter table candid_memory.sessions add foreign key(owner_id,audience_id) references candid_memory.audiences(owner_id,id) on delete cascade;
create trigger session_media_write before insert or update on candid_memory.session_media for each row execute function candid_memory.guard_write();
create trigger session_media_l1 before update on candid_memory.session_media for each row execute function candid_memory.guard_l1();
alter table candid_memory.session_media add foreign key(owner_id,session_id) references candid_memory.sessions(owner_id,id) on delete cascade;
create trigger marks_write before insert or update on candid_memory.marks for each row execute function candid_memory.guard_write();
create trigger marks_l1 before update on candid_memory.marks for each row execute function candid_memory.guard_l1();
alter table candid_memory.marks add foreign key(owner_id,session_id) references candid_memory.sessions(owner_id,id) on delete cascade;
create trigger transcript_segments_write before insert or update on candid_memory.transcript_segments for each row execute function candid_memory.guard_write();
create trigger transcript_segments_l1 before update on candid_memory.transcript_segments for each row execute function candid_memory.guard_l1();
alter table candid_memory.transcript_segments add foreign key(owner_id,session_id) references candid_memory.sessions(owner_id,id) on delete cascade;
create trigger qa_units_write before insert or update on candid_memory.qa_units for each row execute function candid_memory.guard_write();
alter table candid_memory.qa_units add foreign key(owner_id,session_id) references candid_memory.sessions(owner_id,id) on delete cascade;
create trigger metrics_write before insert or update on candid_memory.metrics for each row execute function candid_memory.guard_write();
alter table candid_memory.metrics add foreign key(owner_id,session_id) references candid_memory.sessions(owner_id,id) on delete cascade;
alter table candid_memory.metrics add foreign key(owner_id,unit_id) references candid_memory.qa_units(owner_id,id) on delete cascade;
create trigger diagnoses_write before insert or update on candid_memory.diagnoses for each row execute function candid_memory.guard_write();
alter table candid_memory.diagnoses add foreign key(owner_id,session_id) references candid_memory.sessions(owner_id,id) on delete cascade;
alter table candid_memory.diagnoses add foreign key(owner_id,unit_id) references candid_memory.qa_units(owner_id,id) on delete cascade;
create trigger diagnosis_feedback_write before insert or update on candid_memory.diagnosis_feedback for each row execute function candid_memory.guard_write();
alter table candid_memory.diagnosis_feedback add foreign key(owner_id,diagnosis_id) references candid_memory.diagnoses(owner_id,id) on delete cascade;

create table candid_memory.limits(key text primary key, value int);
insert into candid_memory.limits values ('asset_limit',null);
create table candid_memory.deletion_log(id uuid primary key default gen_random_uuid(),object_id uuid not null,object_type text not null,deleted_at timestamptz not null default now(),reason text not null);
create table candid_memory.llm_calls(id uuid primary key default gen_random_uuid(),producer text,purpose text,input_tokens int,output_tokens int,latency_ms int);
create table candid_memory.jobs(id uuid primary key default gen_random_uuid(),owner_id uuid not null references auth.users(id) on delete cascade,session_id uuid references candid_memory.sessions(id) on delete cascade,stage text not null,status text not null default 'queued',attempts int not null default 0,available_at timestamptz not null default now());
alter table candid_memory.jobs enable row level security;
alter table candid_memory.deletion_log enable row level security;
alter table candid_memory.llm_calls enable row level security;
alter table candid_memory.limits enable row level security;
-- Internal queue claim uses row locks, and serializes jobs per session.
create unique index jobs_session_active on candid_memory.jobs(session_id) where status in ('queued','running');
create function candid_memory.claim_job() returns setof candid_memory.jobs language sql security definer set search_path=pg_catalog,candid_memory as $$
 update candid_memory.jobs set status='running' where id=(select id from candid_memory.jobs where status='queued' and available_at<=now() order by available_at for update skip locked limit 1) returning *;
$$;
revoke all on function candid_memory.claim_job() from public,anon,authenticated;
grant execute on function candid_memory.claim_job() to service_role;
grant usage on schema candid_memory to authenticated,service_role;
grant select,insert,update,delete on all tables in schema candid_memory to authenticated;
grant all on all tables in schema candid_memory to service_role;
-- RLS denies authenticated access to system tables (no policies).
insert into storage.buckets(id,name,public) values ('candid-audio','candid-audio',false),('candid-documents','candid-documents',false) on conflict(id) do nothing;
create policy candid_storage_owner on storage.objects for all to authenticated
using(bucket_id in ('candid-audio','candid-documents') and (storage.foldername(name))[1]=auth.uid()::text)
with check(bucket_id in ('candid-audio','candid-documents') and (storage.foldername(name))[1]=auth.uid()::text);
commit;
-- Storage object deletion and pg_cron scheduling require a configured worker URL/token.
-- Do not enable a fake cron target. Runtime prototype worker is in backend/app.py.
