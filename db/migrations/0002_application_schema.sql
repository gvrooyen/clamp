-- Derived concept index, lossy access telemetry, and the singleton Git index
-- checkpoint. Git remains the authoritative source of knowledge.
CREATE TABLE public.concepts (
    path                 pg_catalog.text PRIMARY KEY,
    blob_hash            pg_catalog.text NOT NULL,
    embedding_input_hash pg_catalog.text NOT NULL,
    type                 pg_catalog.text NOT NULL,
    title                pg_catalog.text,
    description          pg_catalog.text,
    tags                 pg_catalog.text[] NOT NULL DEFAULT '{}',
    body                 pg_catalog.text NOT NULL,
    frontmatter          pg_catalog.jsonb NOT NULL,
    status               pg_catalog.text NOT NULL DEFAULT 'stable'
                         CHECK (status IN ('draft', 'stable', 'deprecated')),
    stale_after          pg_catalog.date,
    generated_by         pg_catalog.text,
    generated_at         pg_catalog.timestamptz,
    asserted_by          pg_catalog.text,
    verified_tier        pg_catalog.text NOT NULL
                         CHECK (verified_tier IN (
                             'unverified',
                             'machine-confirmed',
                             'human-reviewed'
                         )),
    task_state           pg_catalog.text CHECK (task_state IS NULL OR task_state IN (
                             'todo', 'doing', 'blocked', 'done', 'cancelled'
                         )),
    task_priority        pg_catalog.text CHECK (task_priority IS NULL OR task_priority IN (
                             'low', 'normal', 'high', 'urgent'
                         )),
    task_due_on          pg_catalog.date,
    task_due_at          pg_catalog.timestamptz,
    task_completed_at    pg_catalog.timestamptz,
    embedding_model      pg_catalog.text NOT NULL,
    embedding            public.vector(1536) NOT NULL,
    indexed_at           pg_catalog.timestamptz NOT NULL DEFAULT pg_catalog.now(),
    CHECK (task_due_on IS NULL OR task_due_at IS NULL)
);

CREATE INDEX concepts_embedding_hnsw_idx
    ON public.concepts USING hnsw (embedding public.vector_cosine_ops);

CREATE TABLE public.access_stats (
    concept_path         pg_catalog.text PRIMARY KEY
                         REFERENCES public.concepts(path) ON DELETE CASCADE,
    last_accessed_at     pg_catalog.timestamptz,
    access_count         pg_catalog.int8 NOT NULL DEFAULT 0
                         CHECK (access_count >= 0)
);

CREATE TABLE public.index_state (
    id                   pg_catalog.int2 PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    source_repository    pg_catalog.text NOT NULL,
    source_ref           pg_catalog.text NOT NULL DEFAULT 'refs/heads/main',
    last_indexed_commit  pg_catalog.text,
    embedding_model      pg_catalog.text NOT NULL,
    embedding_dimensions pg_catalog.int4 NOT NULL,
    last_indexed_at      pg_catalog.timestamptz
);
