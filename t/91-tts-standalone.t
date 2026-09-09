use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);

use lib "$Bin/../lib";
require D2TG::TTS;

# TGT-106 (user-supplied feature-gap analysis): the old ~/skills/tg
# blueprint exposed text-to-speech as its own standalone step, callable
# by anything on the project - the new skill's D2TG::TTS::synthesize
# does the same underlying work, but was only ever reachable from
# inside D2TG::Reply::send_reply. synthesize_to_file wraps the existing
# (unchanged) synthesize with the "write to a given path, or a sensible
# default" plumbing that cli/tts.pl needs - no new synthesis logic.

{
    eval { D2TG::TTS::synthesize_to_file('') };
    like( $@, qr/must not be empty/, 'synthesize_to_file delegates empty-text validation to synthesize unchanged' );
}

{
    my @calls;
    my $runner = sub { push @calls, [@_]; return 0; };

    my $path = D2TG::TTS::synthesize_to_file( 'hello world', runner => $runner );

    is( scalar @calls, 2, 'exactly two commands are run: gtts then ffmpeg (unchanged synthesize behavior)' );
    like( $path, qr/\.ogg$/, 'with no --out, synthesize_to_file returns a sensible default path (the synthesized .ogg itself)' );
    ok( -e $path, 'that default path is a real file on disk (the injected fake runner never writes real audio, so content itself is not asserted here - see t/13-tts.t for synthesize\'s own coverage)' );

    unlink $path;
}

{
    my $runner = sub { return 0; };
    my $out_dir = tempdir( CLEANUP => 1 );
    my $out_path = File::Spec->catfile( $out_dir, 'my-voice-note.ogg' );

    my $result = D2TG::TTS::synthesize_to_file( 'hello there', out => $out_path, runner => $runner );

    is( $result, $out_path, 'with --out given, synthesize_to_file returns exactly that path' );
    ok( -e $out_path, 'the file actually exists at the requested --out path' );
}

{
    # Codex review finding: File::Copy::move silently drops the file
    # INTO an existing directory instead of failing, which would make
    # this return/print the directory's own path, not the file that was
    # actually written - must be rejected explicitly instead.
    my $runner  = sub { return 0; };
    my $out_dir = tempdir( CLEANUP => 1 );

    eval { D2TG::TTS::synthesize_to_file( 'hello', out => $out_dir, runner => $runner ) };
    like( $@, qr/is a directory, not a file path/, 'passing an existing directory as --out is rejected, not silently misplaced' );
}

{
    # The move() itself (not the synthesis step) failing - e.g. the
    # requested --out path's parent directory doesn't exist - must
    # still die loudly and never leave a partial file at $out.
    my $runner   = sub { return 0; };    # synthesis itself succeeds
    my $out_path = File::Spec->catfile( '/nonexistent-dir-for-tgt106-test', 'unreachable.ogg' );

    eval { D2TG::TTS::synthesize_to_file( 'hello', out => $out_path, runner => $runner ) };
    like( $@, qr/cannot write to/, 'a failure to move the file to --out (not a synthesis failure) still dies loudly' );
    ok( !-e $out_path, 'no file is left behind when the destination itself is unreachable' );
}

{
    # A synthesis failure must still propagate loudly - no silent empty
    # file at the requested --out path.
    my $runner = sub { return 1; };    # gtts fails immediately
    my $out_dir = tempdir( CLEANUP => 1 );
    my $out_path = File::Spec->catfile( $out_dir, 'never-written.ogg' );

    eval { D2TG::TTS::synthesize_to_file( 'hello', out => $out_path, runner => $runner ) };
    like( $@, qr/gtts-cli failed/, 'a synthesis failure still dies loudly, matching this skill\'s fail-loud TTS convention' );
    ok( !-e $out_path, 'no file is left behind at the requested --out path on failure' );
}

# CLI-level: argument validation only, no real network/gtts-cli call -
# matching this project's established convention (t/78's own precedent:
# "no real network call in tests" - a full successful synthesis is
# tested at the lib level above via an injected runner).
{
    my $tts_cli = File::Spec->catfile( $Bin, '..', 'cli', 'tts.pl' );

    my $out = `$tts_cli 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/tts.pl with no text argument refuses' );
    like( $out, qr/Usage: d2 tg\.tts/, 'the message names the correct usage' );
}

{
    my $tts_cli = File::Spec->catfile( $Bin, '..', 'cli', 'tts.pl' );

    my $out = `$tts_cli --out 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/tts.pl with a bare trailing --out (no value) refuses instead of misparsing' );
    like( $out, qr/--out.*requires a value/i, 'the message names the actual problem' );
}

done_testing();
