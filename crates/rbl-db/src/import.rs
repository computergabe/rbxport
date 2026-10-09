//! Reading a file's tags, so a track can be added to the library.
//!
//! Separate from the writer: what a file says about itself is a different
//! question from what the database should record, and keeping them apart means
//! the tag reading is testable without a database at all.

use std::path::Path;

use lofty::config::ParseOptions;
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::prelude::ItemKey;
use lofty::probe::Probe;

/// Extensions rekordbox will play, and so the only ones worth importing.
pub const AUDIO_EXTENSIONS: &[&str] =
    &["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus"];

/// What a file says about itself.
///
/// Every field is optional because tags routinely are: an untagged file is
/// still importable, it just arrives with its filename as its title.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TrackTags {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub genre: String,
    pub label: String,
    pub comment: String,
    /// Seconds, rounded.
    pub duration_sec: u32,
    pub bitrate: u32,
    pub sample_rate: u32,
    pub year: u16,
    pub track_no: u16,
    pub file_size: u64,
    /// Bits per sample; 16 when the format does not say (an MP3), which is
    /// what rekordbox records for one.
    pub bit_depth: u8,
    /// The musical key the tag names, as written there (`Am`, `8A`); empty
    /// when it names none. See [`tag_key`].
    pub key: String,
}

/// The MP4 atom rekordbox takes a key from. Not lofty's `InitialKey`
/// mapping (`----:com.apple.iTunes:initialkey`): rekordbox's `parseKey`
/// names this one and no other [OBS: see [`tag_key`]].
const MP4_KEY: &str = "----:com.apple.iTunes:KEY";

/// The key a file's tags name, read where rekordbox reads it.
///
/// rekordbox 7.2.11 (macOS arm64) `TagLib::ParseTag::parseKey` @0x100c6ff10
/// [OBS static]: the `ID3v2` tag's `TKEY` when the file has a non-empty `ID3v2`
/// tag; otherwise the MP4 atom [`MP4_KEY`]; otherwise the Vorbis comment
/// `INITIALKEY`. A non-empty `ID3v2` tag without a `TKEY` gives no key; the
/// other tags are not consulted. Import (`DatabaseMediator::addTrack`
/// @0x10166eae8) and Reload Tag (`DatabaseMediator::readTag` @0x100aa41ec)
/// both store it through `convertTagData` @0x100aa4be0, which copies the key
/// when it is not empty and leaves the tag's BPM unused, so a BPM tag is not
/// read here either. Surrounding whitespace is dropped so one key does not
/// become two `djmdKey` rows [ASSUME: rekordbox keeps the text as is].
fn tag_key(tagged: &lofty::file::TaggedFile) -> String {
    use lofty::tag::{TagExt, TagType};
    let found = if let Some(id3) = tagged.tag(TagType::Id3v2).filter(|t| !t.is_empty()) {
        id3.get_string(&ItemKey::InitialKey)
    } else if let Some(mp4) = tagged.tag(TagType::Mp4Ilst).filter(|t| !t.is_empty()) {
        mp4.get_string(&ItemKey::Unknown(MP4_KEY.to_owned()))
    } else {
        tagged.tag(TagType::VorbisComments).and_then(|t| t.get_string(&ItemKey::InitialKey))
    };
    found.map(str::trim).unwrap_or_default().to_owned()
}

/// `djmdContent.FileType` for a file, by extension: what rekordbox writes on
/// 38,681 reference rows [OBS] — 1 on every `.mp3`, 4 on `.m4a`, 5 on `.flac`,
/// 11 on `.wav`, 12 on `.aiff`/`.aif`. Anything else is unseen and left unset.
#[must_use]
pub fn file_type(path: &Path) -> Option<i64> {
    match path.extension()?.to_str()?.to_ascii_lowercase().as_str() {
        "mp3" => Some(1),
        "m4a" => Some(4),
        "flac" => Some(5),
        "wav" => Some(11),
        "aiff" | "aif" => Some(12),
        _ => None,
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ImportError {
    #[error("{0} is not a file")]
    NotAFile(String),
    #[error("{extension:?} is not a format rekordbox plays")]
    UnsupportedFormat { extension: String },
    #[error("could not read {path}: {reason}")]
    Unreadable { path: String, reason: String },
}

/// Whether a path looks like something worth importing.
#[must_use]
pub fn is_audio(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .map(str::to_ascii_lowercase)
        .is_some_and(|e| AUDIO_EXTENSIONS.contains(&e.as_str()))
}

/// Reads embedded artwork separately from the fast Explorer tag probe.
/// Prefer a front cover across all tags, then the first available picture.
pub fn read_artwork(path: &Path) -> Result<Option<Vec<u8>>, ImportError> {
    let tagged = Probe::open(path)
        .map(|probe| probe.options(ParseOptions::new().read_properties(false)))
        .and_then(Probe::read)
        .map_err(|e| ImportError::Unreadable {
            path: path.display().to_string(),
            reason: e.to_string(),
        })?;
    let pictures = || tagged.tags().iter().flat_map(lofty::tag::Tag::pictures);
    Ok(pictures()
        .find(|p| p.pic_type() == lofty::picture::PictureType::CoverFront)
        .or_else(|| pictures().next())
        .map(|p| p.data().to_vec()))
}

/// Reads a file's tags.
///
/// A missing title falls back to the file's own name rather than being left
/// empty: a library row with no title is unusable, and the filename is what
/// the person actually recognises.
pub fn read_tags(path: &Path) -> Result<TrackTags, ImportError> {
    if !path.is_file() {
        return Err(ImportError::NotAFile(path.display().to_string()));
    }
    if !is_audio(path) {
        return Err(ImportError::UnsupportedFormat {
            extension: path
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or_default()
                .to_owned(),
        });
    }

    // Without the cover art. Nothing here stores a picture, and a picture is
    // most of a tag by size: reading it made one probe cost 15 ms on a local
    // disk and 56 ms cold from an SD card against under a millisecond
    // without [OBS], which is the difference between an Explorer page that
    // lands and one that stalls.
    let tagged = Probe::open(path)
        .map(|probe| probe.options(ParseOptions::new().read_cover_art(false)))
        .and_then(lofty::probe::Probe::read)
        .map_err(|e| ImportError::Unreadable {
            path: path.display().to_string(),
            reason: e.to_string(),
        })?;

    let properties = tagged.properties();
    let mut tags = TrackTags {
        duration_sec: u32::try_from(properties.duration().as_secs()).unwrap_or(0),
        bitrate: properties.audio_bitrate().unwrap_or(0),
        sample_rate: properties.sample_rate().unwrap_or(0),
        file_size: std::fs::metadata(path).map_or(0, |m| m.len()),
        bit_depth: properties.bit_depth().unwrap_or(16),
        ..TrackTags::default()
    };

    // A file can carry several tags: an MP3 often has an ID3v2 and an ID3v1,
    // a WAV an `id3 ` chunk and RIFF INFO. Each field comes from the primary
    // tag when that has it, else from the first other tag that does. Reading
    // the primary tag alone lost an artist that only the ID3v1 or the RIFF
    // INFO named [OBS: #218 fixtures]; rekordbox reads all of these formats
    // (manual 7.2.18, p.13).
    let primary = tagged.primary_tag();
    let order: Vec<&lofty::tag::Tag> = primary
        .into_iter()
        .chain(tagged.tags().iter().filter(|t| primary.is_none_or(|p| p.tag_type() != t.tag_type())))
        .collect();
    let first = |key: &ItemKey| {
        order
            .iter()
            .find_map(|tag| tag.get_string(key).filter(|v| !v.trim().is_empty()))
    };
    let text = |key: &ItemKey| first(key).unwrap_or_default().to_owned();
    tags.title = text(&ItemKey::TrackTitle);
    tags.artist = text(&ItemKey::TrackArtist);
    tags.album = text(&ItemKey::AlbumTitle);
    tags.genre = text(&ItemKey::Genre);
    tags.label = text(&ItemKey::Label);
    tags.comment = text(&ItemKey::Comment);
    tags.year = order
        .iter()
        .find_map(|tag| {
            tag.get_string(&ItemKey::RecordingDate)
                .and_then(|v| v.get(..4).and_then(|y| y.parse().ok()))
                .or_else(|| tag.get_string(&ItemKey::Year).and_then(|v| v.parse().ok()))
                .filter(|&y: &u16| y != 0)
        })
        .unwrap_or(0);
    tags.track_no = order
        .iter()
        .find_map(|tag| {
            tag.get_string(&ItemKey::TrackNumber)
                // "3/12" is a legal track number; take the part before the slash.
                .and_then(|v| v.split('/').next().and_then(|n| n.trim().parse().ok()))
                .filter(|&n: &u16| n != 0)
        })
        .unwrap_or(0);
    tags.key = tag_key(&tagged);

    if tags.title.is_empty() {
        tags.title = path
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
    }
    Ok(tags)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn audio_files_are_recognised_by_extension() {
        for good in ["a.mp3", "a.M4A", "a.flac", "a.aiff", "a.wav"] {
            assert!(is_audio(Path::new(good)), "{good}");
        }
        for bad in ["a.txt", "a.jpg", "a", "a.mp4", "a.mp3.txt"] {
            assert!(!is_audio(Path::new(bad)), "{bad}");
        }
    }

    #[test]
    fn a_file_that_is_not_there_is_refused_before_anything_is_read() {
        let outcome = read_tags(Path::new("/no/such/file.mp3"));
        assert!(matches!(outcome, Err(ImportError::NotAFile(_))));
    }

    #[test]
    fn a_format_rekordbox_cannot_play_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("notes.txt");
        std::fs::write(&path, b"x").unwrap();
        assert!(matches!(
            read_tags(&path),
            Err(ImportError::UnsupportedFormat { .. })
        ));
    }

    use lofty::config::WriteOptions;
    use lofty::prelude::TagExt;
    use lofty::tag::{Tag, TagType};

    /// Forty silent MPEG-1 Layer III frames: 128 kbps, 44.1 kHz, 417 bytes
    /// each, enough for the probe to find a stream.
    fn write_mp3(path: &Path) {
        let mut out = Vec::new();
        for _ in 0..40 {
            let start = out.len();
            out.extend_from_slice(&[0xFF, 0xFB, 0x90, 0x64]);
            out.resize(start + 417, 0);
        }
        std::fs::write(path, out).unwrap();
    }

    /// One second of 16-bit mono silence.
    fn write_wav(path: &Path) {
        let rate = 44_100_u32;
        let data_len = rate * 2;
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data_len).to_le_bytes());
        out.extend_from_slice(b"WAVEfmt ");
        out.extend_from_slice(&16_u32.to_le_bytes());
        out.extend_from_slice(&1_u16.to_le_bytes());
        out.extend_from_slice(&1_u16.to_le_bytes());
        out.extend_from_slice(&rate.to_le_bytes());
        out.extend_from_slice(&(rate * 2).to_le_bytes());
        out.extend_from_slice(&2_u16.to_le_bytes());
        out.extend_from_slice(&16_u16.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&data_len.to_le_bytes());
        out.resize(44 + data_len as usize, 0);
        std::fs::write(path, out).unwrap();
    }

    fn save_tag(path: &Path, kind: TagType, items: &[(ItemKey, &str)]) {
        let mut tag = Tag::new(kind);
        for (key, value) in items {
            tag.insert_text(key.clone(), (*value).to_owned());
        }
        tag.save_to_path(path, WriteOptions::default()).unwrap();
    }

    #[test]
    fn an_mp3_takes_what_its_id3v2_lacks_from_its_id3v1() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("two tags.mp3");
        write_mp3(&path);
        save_tag(&path, TagType::Id3v1, &[
            (ItemKey::TrackTitle, "Old Title"),
            (ItemKey::TrackArtist, "Only In V1"),
            (ItemKey::AlbumTitle, "V1 Album"),
            (ItemKey::Genre, "House"),
            (ItemKey::Year, "2019"),
            (ItemKey::TrackNumber, "4"),
        ]);
        save_tag(&path, TagType::Id3v2, &[(ItemKey::TrackTitle, "New Title")]);

        let tags = read_tags(&path).unwrap();
        assert_eq!(tags.title, "New Title", "the ID3v2 still wins where it has a value");
        assert_eq!(tags.artist, "Only In V1");
        assert_eq!(tags.album, "V1 Album");
        assert_eq!(tags.genre, "House");
        assert_eq!((tags.year, tags.track_no), (2019, 4));
    }

    #[test]
    fn a_wav_takes_what_its_id3_chunk_lacks_from_its_riff_info() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("both.wav");
        write_wav(&path);
        save_tag(&path, TagType::RiffInfo, &[
            (ItemKey::TrackTitle, "Info Title"),
            (ItemKey::TrackArtist, "Info Artist"),
        ]);
        save_tag(&path, TagType::Id3v2, &[(ItemKey::TrackTitle, "Id3 Title")]);

        let tags = read_tags(&path).unwrap();
        assert_eq!(tags.title, "Id3 Title");
        assert_eq!(tags.artist, "Info Artist");
    }

    #[test]
    fn a_blank_field_in_the_primary_tag_does_not_hide_another_tags_value() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("blank.mp3");
        write_mp3(&path);
        save_tag(&path, TagType::Id3v1, &[(ItemKey::TrackArtist, "Real Artist")]);
        save_tag(&path, TagType::Id3v2, &[(ItemKey::TrackArtist, "  ")]);
        assert_eq!(read_tags(&path).unwrap().artist, "Real Artist");
    }

    #[test]
    fn a_file_with_one_tag_reads_as_before() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("plain.mp3");
        write_mp3(&path);
        save_tag(&path, TagType::Id3v2, &[
            (ItemKey::TrackTitle, "Title"),
            (ItemKey::TrackArtist, "Artist"),
            (ItemKey::RecordingDate, "2021-05-01"),
            (ItemKey::TrackNumber, "3/12"),
        ]);
        let tags = read_tags(&path).unwrap();
        assert_eq!((tags.title.as_str(), tags.artist.as_str()), ("Title", "Artist"));
        assert_eq!((tags.year, tags.track_no), (2021, 3));

        let untagged = dir.path().join("No Tags.mp3");
        write_mp3(&untagged);
        let tags = read_tags(&untagged).unwrap();
        assert_eq!((tags.title.as_str(), tags.artist.as_str()), ("No Tags", ""));
    }

    #[test]
    fn the_key_comes_from_an_id3v2_tkey_as_written() {
        let dir = tempfile::tempdir().unwrap();
        let mp3 = dir.path().join("keyed.mp3");
        write_mp3(&mp3);
        save_tag(&mp3, TagType::Id3v2, &[(ItemKey::TrackTitle, "T"), (ItemKey::InitialKey, "2A")]);
        assert_eq!(read_tags(&mp3).unwrap().key, "2A");

        // A WAV's id3 chunk is an ID3v2 tag too.
        let wav = dir.path().join("keyed.wav");
        write_wav(&wav);
        save_tag(&wav, TagType::Id3v2, &[(ItemKey::TrackTitle, "T"), (ItemKey::InitialKey, " F#m ")]);
        assert_eq!(read_tags(&wav).unwrap().key, "F#m");
    }

    /// A FLAC stream with the given Vorbis comments and no audio frames:
    /// 44.1 kHz, mono, 16-bit, one second. Written by hand, since lofty's
    /// writer wants real frames to write around.
    fn write_flac(path: &Path, comments: &[&str]) {
        let mut out = b"fLaC".to_vec();
        // STREAMINFO (type 0), 34 bytes, not the last block.
        out.extend_from_slice(&[0x00, 0, 0, 34]);
        out.extend_from_slice(&4096_u16.to_be_bytes());
        out.extend_from_slice(&4096_u16.to_be_bytes());
        out.extend_from_slice(&[0; 6]);
        // 20 bits rate (44,100), 3 bits channels - 1 (0), 5 bits depth - 1
        // (15), 36 bits samples (44,100).
        let packed: u64 = (0xAC44 << 44) | (0xF << 36) | 0xAC44;
        out.extend_from_slice(&packed.to_be_bytes());
        out.extend_from_slice(&[0; 16]);
        // VORBIS_COMMENT (type 4), the last block: little-endian lengths.
        let mut block = Vec::new();
        block.extend_from_slice(&4_u32.to_le_bytes());
        block.extend_from_slice(b"test");
        block.extend_from_slice(&u32::try_from(comments.len()).unwrap().to_le_bytes());
        for comment in comments {
            block.extend_from_slice(&u32::try_from(comment.len()).unwrap().to_le_bytes());
            block.extend_from_slice(comment.as_bytes());
        }
        let len = u32::try_from(block.len()).unwrap().to_be_bytes();
        out.extend_from_slice(&[0x84, len[1], len[2], len[3]]);
        out.extend_from_slice(&block);
        std::fs::write(path, out).unwrap();
    }

    #[test]
    fn a_flac_takes_its_key_from_the_initialkey_comment() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("keyed.flac");
        write_flac(&path, &["TITLE=T", "INITIALKEY=Am"]);
        let tags = read_tags(&path).unwrap();
        assert_eq!((tags.title.as_str(), tags.key.as_str()), ("T", "Am"));
    }

    #[test]
    fn a_bpm_tag_does_not_become_a_key_and_no_key_tag_means_no_key() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("bpm only.mp3");
        write_mp3(&path);
        save_tag(&path, TagType::Id3v2, &[(ItemKey::TrackTitle, "T"), (ItemKey::Bpm, "128")]);
        assert_eq!(read_tags(&path).unwrap().key, "");
    }

    #[test]
    fn a_file_with_no_id3v2_does_not_take_a_key_from_its_ape_tag() {
        // rekordbox looks for a key in ID3v2, MP4 and Vorbis comments only.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ape.mp3");
        write_mp3(&path);
        save_tag(&path, TagType::Ape, &[(ItemKey::TrackArtist, "A"), (ItemKey::InitialKey, "Am")]);
        let tags = read_tags(&path).unwrap();
        assert_eq!((tags.artist.as_str(), tags.key.as_str()), ("A", ""));
    }

    #[test]
    fn a_file_that_is_not_really_audio_fails_rather_than_panicking() {
        // The extension says mp3; the bytes do not.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("lying.mp3");
        std::fs::write(&path, b"this is not an mp3").unwrap();
        assert!(matches!(read_tags(&path), Err(ImportError::Unreadable { .. })));
    }
}
