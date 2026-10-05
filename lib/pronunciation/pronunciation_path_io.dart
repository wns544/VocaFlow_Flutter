import 'dart:io';

String pronunciationAudioPath(String rootPath, String relativePath) =>
    '$rootPath${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}';
