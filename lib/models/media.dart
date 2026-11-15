import 'dart:io';

import 'lyrics.dart';

/// Art file and lyrics known for one track.
class TrackMedia {
  const TrackMedia({this.art, this.lyrics, this.title, this.artist, this.album});

  final File? art;
  final Lyrics? lyrics;
  final String? title;
  final String? artist;
  final String? album;
}
