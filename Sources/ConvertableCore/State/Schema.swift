import Foundation

/// Versioned schema. Add a new entry to `migrations` for every change; never edit an applied one.
public enum Schema {
    public static let migrations: [String] = [
        // v1 — initial schema (see docs/DESIGN.md §5). Editable until Phase 7; frozen after.
        """
        CREATE TABLE source_files (
            id              INTEGER PRIMARY KEY,
            rel_path        TEXT NOT NULL UNIQUE,
            artist_dir      TEXT NOT NULL,
            album_dir       TEXT NOT NULL,
            ext             TEXT NOT NULL,
            kind            TEXT NOT NULL CHECK (kind IN ('lossless','lossy','other')),
            codec           TEXT,
            size            INTEGER NOT NULL,
            mtime           REAL NOT NULL,
            stable_since    REAL NOT NULL,
            observations    INTEGER NOT NULL DEFAULT 1,
            missing_since   REAL,
            audio_md5       TEXT,
            tag_hash        TEXT,
            tag_artist      TEXT,
            tag_albumartist TEXT,
            tag_album       TEXT,
            first_seen      REAL NOT NULL,
            last_seen_scan  INTEGER NOT NULL,
            status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','missing','ignored'))
        );
        CREATE INDEX source_files_artist ON source_files(artist_dir);
        CREATE INDEX source_files_album ON source_files(artist_dir, album_dir);
        CREATE INDEX source_files_status ON source_files(status);
        CREATE INDEX source_files_md5 ON source_files(audio_md5);

        CREATE TABLE directories (
            rel_path        TEXT PRIMARY KEY,
            mtime           REAL NOT NULL,
            last_seen_scan  INTEGER NOT NULL,
            status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','missing'))
        );

        CREATE TABLE outputs (
            id                  INTEGER PRIMARY KEY,
            source_id           INTEGER NOT NULL REFERENCES source_files(id) ON DELETE CASCADE,
            rel_path            TEXT NOT NULL UNIQUE,
            size                INTEGER,
            encoder_profile     TEXT NOT NULL,
            audio_md5           TEXT,
            tag_hash            TEXT,
            encoded_at          REAL,
            tags_written_at     REAL,
            verify_ok           INTEGER NOT NULL DEFAULT 0,
            music_persistent_id TEXT,
            music_added_at      REAL
        );
        CREATE INDEX outputs_source ON outputs(source_id);

        CREATE TABLE batches (
            id              INTEGER PRIMARY KEY,
            selection_json  TEXT NOT NULL,
            budget_bytes    INTEGER,
            bytes_in        INTEGER NOT NULL DEFAULT 0,
            bytes_out       INTEGER NOT NULL DEFAULT 0,
            files_done      INTEGER NOT NULL DEFAULT 0,
            started_at      REAL NOT NULL,
            finished_at     REAL,
            ended_by        TEXT CHECK (ended_by IN ('budget','empty','user','error'))
        );

        CREATE TABLE jobs (
            id          INTEGER PRIMARY KEY,
            type        TEXT NOT NULL CHECK (type IN ('encode','copy','retag','music_add','music_refresh','remove','supersede')),
            source_id   INTEGER REFERENCES source_files(id) ON DELETE CASCADE,
            output_id   INTEGER REFERENCES outputs(id) ON DELETE CASCADE,
            batch_id    INTEGER REFERENCES batches(id) ON DELETE SET NULL,
            state       TEXT NOT NULL DEFAULT 'pending'
                        CHECK (state IN ('pending','running','done','failed','awaiting_approval','dismissed')),
            bytes       INTEGER NOT NULL DEFAULT 0,
            attempts    INTEGER NOT NULL DEFAULT 0,
            last_error  TEXT,
            payload     TEXT,
            created_at  REAL NOT NULL,
            started_at  REAL,
            finished_at REAL
        );
        CREATE INDEX jobs_state ON jobs(state, type);
        CREATE INDEX jobs_batch ON jobs(batch_id);

        CREATE TABLE pins (
            artist_dir  TEXT PRIMARY KEY,
            pinned_at   REAL NOT NULL
        );

        CREATE TABLE legacy_files (
            id                  INTEGER PRIMARY KEY,
            rel_path            TEXT NOT NULL UNIQUE,
            size                INTEGER NOT NULL,
            album_artist_norm   TEXT,
            album_norm          TEXT,
            title_norm          TEXT,
            track_no            INTEGER,
            disc_no             INTEGER,
            duration_ms         INTEGER,
            music_persistent_id TEXT,
            indexed_at          REAL NOT NULL
        );
        CREATE INDEX legacy_album ON legacy_files(album_artist_norm, album_norm);

        CREATE TABLE scans (
            id              INTEGER PRIMARY KEY,
            kind            TEXT NOT NULL CHECK (kind IN ('full','incremental')),
            started_at      REAL NOT NULL,
            finished_at     REAL,
            dirs_seen       INTEGER NOT NULL DEFAULT 0,
            files_seen      INTEGER NOT NULL DEFAULT 0,
            resumed_from    TEXT,
            checkpoint      TEXT
        );

        CREATE TABLE activity (
            id          INTEGER PRIMARY KEY,
            at          REAL NOT NULL,
            level       TEXT NOT NULL CHECK (level IN ('debug','info','warn','error')),
            category    TEXT NOT NULL,
            message     TEXT NOT NULL,
            rel_path    TEXT,
            job_id      INTEGER
        );
        CREATE INDEX activity_at ON activity(at);
        """,
        // v2 — Music import bookkeeping (Phase 4)
        """
        ALTER TABLE outputs ADD COLUMN music_attempts INTEGER;
        ALTER TABLE outputs ADD COLUMN music_error TEXT;
        CREATE INDEX outputs_music ON outputs(music_persistent_id);
        """,
        // v3 — review queue (Phase 6)
        """
        ALTER TABLE source_files ADD COLUMN missing_full_scans INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE outputs ADD COLUMN music_refresh_pending INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE outputs ADD COLUMN music_relocate_pending INTEGER NOT NULL DEFAULT 0;
        CREATE TABLE proposals (
            id          INTEGER PRIMARY KEY,
            kind        TEXT NOT NULL CHECK (kind IN ('remove','supersede')),
            artist_dir  TEXT NOT NULL,
            album_dir   TEXT NOT NULL,
            title       TEXT NOT NULL,
            reason      TEXT NOT NULL,
            items_json  TEXT NOT NULL,
            bytes       INTEGER NOT NULL DEFAULT 0,
            created_at  REAL NOT NULL,
            state       TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','approved','dismissed','done','failed')),
            decided_at  REAL,
            done_at     REAL,
            error       TEXT
        );
        CREATE INDEX proposals_state ON proposals(state);
        """,
        // v4 — legacy library supersede (Phase 6b)
        """
        ALTER TABLE legacy_files ADD COLUMN root TEXT NOT NULL DEFAULT '';
        ALTER TABLE legacy_files ADD COLUMN mtime REAL;
        ALTER TABLE legacy_files ADD COLUMN superseded_at REAL;
        ALTER TABLE legacy_files ADD COLUMN title TEXT;
        ALTER TABLE legacy_files ADD COLUMN album_artist TEXT;
        ALTER TABLE legacy_files ADD COLUMN album TEXT;
        """,
        // v5 — tag policy versioning: bump TagPolicy.version to re-sync every mirror file's metadata from its source
        """
        ALTER TABLE outputs ADD COLUMN tag_policy INTEGER NOT NULL DEFAULT 0;
        """,
        // v6 — proposals may also be 'dead' (Music entries whose files no longer exist)
        """
        CREATE TABLE proposals_v6 (
            id          INTEGER PRIMARY KEY,
            kind        TEXT NOT NULL CHECK (kind IN ('remove','supersede','dead')),
            artist_dir  TEXT NOT NULL,
            album_dir   TEXT NOT NULL,
            title       TEXT NOT NULL,
            reason      TEXT NOT NULL,
            items_json  TEXT NOT NULL,
            bytes       INTEGER NOT NULL DEFAULT 0,
            created_at  REAL NOT NULL,
            state       TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','approved','dismissed','done','failed')),
            decided_at  REAL,
            done_at     REAL,
            error       TEXT
        );
        INSERT INTO proposals_v6 SELECT * FROM proposals;
        DROP TABLE proposals;
        ALTER TABLE proposals_v6 RENAME TO proposals;
        CREATE INDEX proposals_state ON proposals(state);
        """,
    ]

    public static var currentVersion: Int { migrations.count }

    /// Applies any migrations newer than the database's `user_version`, each in its own transaction.
    public static func migrate(_ db: Database) throws {
        let have = db.userVersion
        guard have < migrations.count else { return }
        for (i, sql) in migrations.enumerated() where i >= have {
            try db.transaction {
                try db.exec(sql)
                try db.setUserVersion(i + 1)
            }
        }
    }
}
