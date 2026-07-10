# Hardlink-Aware Indexing

## 1. Design goal

EverythingOnMac must preserve every searchable directory entry while avoiding repeated content reads for paths that refer to the same hardlinked file object.

The implementation deliberately distinguishes three concepts:

- **Hardlink**: same volume UUID and file ID; one object may have multiple directory entries.
- **APFS Clone**: normally has a different file ID and remains a separate object.
- **Ordinary duplicate**: also remains separate unless a future content-fingerprint layer explicitly deduplicates content indexing.

No decision is made from size and modification date alone.

## 2. Database model

Schema version 6 replaces the former `fs_nodes` table with two layers.

### `fs_objects`

Represents filesystem object identity and object-level metadata:

- `volume_uuid`
- `file_id`
- `is_directory`
- `file_extension`
- `size`
- `modification_date`
- `uti`
- `link_count`
- reserved `content_fingerprint`

Primary key:

```sql
PRIMARY KEY (volume_uuid, file_id)
```

### `fs_entries`

Represents a searchable directory entry:

- `entry_id`
- `volume_uuid`
- `parent_file_id`
- `target_file_id`
- `name`
- `name_character_mask`

Uniqueness is scoped to a directory:

```sql
UNIQUE (volume_uuid, parent_file_id, name)
```

`target_file_id` references `fs_objects`. Multiple entries may therefore point to one object.

Object upserts use `ON CONFLICT DO UPDATE`, not `INSERT OR REPLACE`. SQLite `REPLACE` deletes the existing row before inserting a new row and would trigger cascading deletion of existing hardlink entries.

## 3. Migration behavior

Older indexes cannot recover hardlink paths that were already overwritten by the former `(volume_uuid, file_id)` primary key.

The v6 migration therefore:

1. creates `fs_objects` and `fs_entries`;
2. removes `fs_nodes`;
3. clears the last FSEvents ID;
4. sets `metadata.rebuild_required = 1`;
5. commits the migration atomically.

A complete rebuild is required after migration.

## 4. Indexing behavior

Full scans and recursive scans build separate object and entry batches.

- Object rows are deduplicated within each batch by `FileIdentity`.
- Entry rows are never deduplicated by file identity.
- SQLite uniqueness provides the final object-level deduplication boundary.

`FileIdentity` is:

```swift
struct FileIdentity: Hashable, Sendable {
    let volumeUUID: String
    let fileID: UInt64
}
```

## 5. Query and path behavior

Filename and path-oriented fields come from `fs_entries`:

- name
- character mask
- parent relationship
- path-prefix traversal

Object metadata comes from `fs_objects`:

- size
- modification date
- UTI
- extension
- directory flag

Each search result carries both object and entry identity:

- `volumeUUID`
- `fileID`
- `entryID`
- resolved path

Two hardlink paths therefore produce two results with the same file ID and different entry IDs.

Path recovery starts from the entry's parent file ID and name. Missing parents, parent cycles, and excessive depth are reported as index corruption; no synthetic path is generated.

## 6. Incremental updates

### Create or modify

The indexer upserts the object and then upserts the directory entry in one transaction.

Creating another hardlink adds a new entry without replacing the existing entry.

### Remove

Removal is located by the surviving parent directory's volume UUID and file ID plus the deleted entry name.

The indexer:

1. deletes the matching entry;
2. deletes descendants when the entry is a directory;
3. deletes objects that no longer have any entry references.

Deleting one hardlink therefore leaves the shared object and remaining paths intact. Deleting the final link removes the object.

### Rename or move

The event pipeline treats a move as removal of the old entry and insertion of the new entry. The object identity remains unchanged when the file ID remains unchanged.

## 7. Content search deduplication

Content search no longer recursively passes roots directly to ripgrep in the hardlink-aware coordinator path.

The sequence is:

1. `FileIndexer.contentCandidates` selects eligible file identities using path and metadata constraints.
2. The candidate limit is applied to **file identities**, not entries.
3. All eligible entries for each selected identity are returned, so a limit can never split a hardlink set.
4. `SearchCoordinator` groups entries by `FileIdentity`.
5. One readable representative path is selected per identity.
6. `RipgrepSearcher` scans only those representative paths.
7. Every match is mapped back to all eligible entries for that identity.

Thus one file object is read once while every real path remains visible.

Explicit file paths are split into command batches at approximately 96 KiB of argument data to avoid exceeding process argument limits. Batches preserve cancellation, timeout, error propagation, and streaming output.

## 8. Candidate semantics

Content terms are not used as filename predicates for content candidates. Candidate selection only applies structural and metadata constraints such as:

- path prefix
- extension
- size and date
- UTI
- excluded entry names
- excluded paths

The actual content pattern is evaluated by ripgrep.

The candidate cap and truncation flag are identity-based. If one selected object has multiple hardlink paths, all matching paths are retained even when the identity limit is one.

## 9. APFS Clone policy

APFS Clones are not merged by this subsystem.

A clone with a different file ID becomes a separate `fs_objects` row and is scanned independently. A future content fingerprint may allow sharing derived content-index data, but it must not merge filesystem identity or remove independent paths.

## 10. Verification

The test suite covers:

- schema creation and migration rebuild flag;
- foreign-key behavior;
- multiple entries for one object;
- independent hardlink deletion and final-object cleanup;
- filename and path search for each hardlink;
- different entry IDs with the same file ID;
- one content scan per identity;
- mapping one content match to every hardlink entry;
- identity-based candidate limits that do not split a hardlink set;
- path-prefix, sorting, pagination, fuzzy matching, corruption handling, timeout, cancellation, and streaming regressions.

Required verification commands:

```bash
swift test
swift build -c release
```
