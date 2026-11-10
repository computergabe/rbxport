# Windows import internals

This records what the Music to Rekordbox importer (this fork's 1.3 releases)
has to do for rekordbox 7 to accept imported tracks, and how each rule was
found. Everything here was observed on rekordbox 7.2.19 on Windows 11 with
the maintainer's real library. User instructions are in the
[Windows import guide](../user/windows-import.md).

## The pipeline

One click of **Music → Rekordbox** (or **Import from inbox** in the window):

1. `Music-Import.Core.psm1` finds ZIPs and audio in the inbox folders and
   extracts ZIPs to a staging folder.
2. `rbxport.exe --inspect-list` reads each file's tags.
3. Missing tags are filled from the file and folder names
   (`Get-MusicNameTags`), and artist spellings are applied.
4. Each file is copied to a temporary name in the music library folder and its
   SHA-256 verified; `rbxport.exe --write-tags` writes the filled tags into
   that copy; the tagged copy is checked against existing files for
   duplicates, then moved to its final Artist/Album/Filename path.
5. The final paths are saved in `Music-Import.pending.json`.
6. `rbxport.exe --import ... --analyze --analyze-bpm <range>` registers the
   paths in the active library and analyzes them. Paths leave the queue only
   after a complete, successful report.

The original download is never written to. In Move mode it is deleted only
after the queue is saved.

## What rekordbox requires

### Analysis files are fingerprinted (`contentFile`)

rekordbox records each analysis file (`.DAT`, `.EXT`, `.2EX`) in the
`contentFile` table with its MD5 hash and size. When the file on disk does
not match its row, or there is no row, rekordbox treats the track as
unanalyzed and offers to analyze it again. Analysis written without updating
`contentFile` therefore "did not stick". `rbl-db` now writes those rows after
writing analysis (see the module notes in `crates/rbl-db/src/write.rs`), and
leaves rows that already match untouched.

### `PPTH` must use the share-tree form

Each analysis file starts with a `PPTH` section naming its audio file. In a
desktop library, rekordbox 7.2.19 writes `?/<file name>` there (the share
tree form), not the full path. With a full path, the analysis loaded but
rekordbox ignored the beat grid: Beat Sync reported "The track has no beat
grid information". `rbl_anlz::share_tree_ppth` produces the right form. Tracks
analyzed by RBXPORT before 1.3.0 have the old form, and the importer
re-analyzes them when they are imported again.

Section order matters too. The files rekordbox accepts are laid out as:

| File | Sections |
| --- | --- |
| `.DAT` | `PPTH PVBR PQTZ PWAV PWV2 PCOB PCOB` |
| `.EXT` | `PPTH PWV3 PCOB PCOB PCO2 PCO2 PWV5 PWV4` |
| `.2EX` | `PPTH PWV7 PWV6` |

Sections rekordbox wrote that RBXPORT cannot author (and cue lists with
cues) are carried through from an existing file. This was ported from
upstream commit `6f3a417b`.

### The `analysed` column

`djmdContent.Analysed` holds a bitmask in the database (105 for a fully
analyzed track), while RBXPORT's index reports it as 0 or 1. Tests compare
against the index value.

### Paths ignore case and slash direction on Windows

rekordbox can store a path with different capitalization than the file
system reports. Looking up a track by an exact path missed it, and the same
file was registered twice (two rows of one track, one with a half-time BPM).
`track_id_at` now compares `FolderPath` with `COLLATE NOCASE` on Windows.

rekordbox itself stores Windows paths with forward slashes
(`C:/Users/...`). Up to 1.3.1 the importer stored them with backslashes, so
a file rekordbox had added and the importer then imported again got a second
row: 245 of the maintainer's 312 tracks were in the Collection twice. Paths
are now stored with forward slashes, and the lookup and the duplicate check
compare with backslashes turned into forward slashes.

### Static grids

The analyzer splits a track into tempo segments where it hears a tempo
change, a ramp or a gap. That is a Dynamic grid, and DJ tools treat it
differently from a fixed tempo. Imports use `TempoOptions::constant`: the
whole track is fitted as one line at one BPM, as rekordbox's Normal mode
does. The RBXPORT app's own Analyze dialog still produces segmented grids.

### Streaming tracks are not files

Tracks from streaming services store a link such as `spotify:track:...` in
`FolderPath`, with encrypted titles. The missing-file check skips anything
that is a link; in the maintainer's library that was 130 rows that would
otherwise have been reported missing.

### File size changes make a track "missing"

rekordbox records each file's size. When another program rewrites the file,
for example a tag editor, rekordbox can list the track as missing although
the file is in place. **Reload Tag** in rekordbox records the new size. The
importer avoids this by writing tags into its own copy before registering it.

### Half-time BPM

Fast tracks (drum & bass at 175) are often detected at half tempo (87.50).
The importer passes a BPM range to the analyzer (`--analyze-bpm`, default
`70-180`); a tempo outside the range is doubled or halved into it. The
maintainer uses `90-180`.

## WAV tags

`lofty` 0.22 treats ID3v2 as the primary tag of a WAV file, and RBXPORT's tag
reader reads the primary tag (or the first tag present). Many downloaded WAVs
carry only RIFF INFO tags, so writing just the new fields into a fresh ID3v2
tag would have hidden the existing INFO values. `music_tag.rs` copies the
existing values into the new primary tag before adding the filled ones.

## Real-world test

On 2026-11-02 a 1.79 GB ZIP of 41 untagged WAV and MP3 files ("Dubplates")
was imported with Move, tags from names, `IMMIX` as an artist spelling, the
`Dub Plates` default album and the `90-180` range:

- 41 tracks tagged, sorted, registered and analyzed; 0 errors.
- 123 of 123 analysis fingerprints matched `contentFile`.
- A 175 BPM track first read at 87.50 was re-analyzed at 175.
- The missing-file check reported nothing after skipping 130 streaming tracks.
- The maintainer then played the tracks in rekordbox; grids, BPM and Beat
  Sync worked, and rekordbox did not ask to analyze them again.

The ZIP's artwork and other non-audio files went to
`_archive-extras\Dubplates-<hash>` in the music library folder.

## Release history

| Version | What changed |
| --- | --- |
| 1.3.0 | The Music to Rekordbox window; analysis while importing; `contentFile` fingerprints; share-tree `PPTH` so Beat Sync works. |
| 1.3.1 | Tags from file and folder names; artist spellings; BPM range; Fix missing files; case-insensitive path lookup. |
| next | Static (one-BPM) grids for imports; paths stored with forward slashes and matched with either slash. |

## Known limits

- Only rekordbox 7.2.19 has been checked. Another version may change what it
  accepts in analysis files or `contentFile`.
- Some tempos still need a manual fix (one track reads 116.67 BPM).
- Files with no artist in their names stay under `Unknown Artist`.
- The Windows folder picker dialog is not driven by an automated test.
