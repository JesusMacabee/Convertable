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
