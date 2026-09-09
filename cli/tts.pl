#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Encode qw(decode);

use D2TG::Config;
use D2TG::TTS;

my $out;
while (@ARGV) {
    if ( $ARGV[0] eq '--out' ) {
        shift @ARGV;
        $out = eval { D2TG::Config::shift_flag_value( \@ARGV, '--out' ) };
        if ($@) {
            print STDERR $@;
            exit 1;
        }
    }
    else {
        last;
    }
}

my $text = join( ' ', map { decode( 'UTF-8', $_ ) } @ARGV );

if ( !length $text ) {
    print STDERR "Usage: d2 tg.tts [--out <path>] <text...>\n";
    exit 2;
}

my $path = eval { D2TG::TTS::synthesize_to_file( $text, out => $out ) };
if ($@) {
    print STDERR $@;
    exit 1;
}

print "$path\n";
exit 0;

=head1 NAME

tts - synthesize text to a local audio file with no Telegram interaction, dispatched as C<d2 tg.tts>

=head1 SYNOPSIS

    d2 tg.tts <text...>
    d2 tg.tts --out <path> <text...>

=head1 DESCRIPTION

TGT-106 (user-supplied feature-gap analysis): the old C<~/skills/tg>
blueprint's text-to-speech step was a small, self-contained piece
callable directly by anything on the project - the new skill's
L<D2TG::TTS/synthesize> does the same underlying work, but was only
ever reachable from inside L<D2TG::Reply/send_reply>. This command
exposes it directly: text in, an audio file out, no Telegram message
sent at all. Useful for anything that just needs a spoken audio file -
e.g. attaching a voice note to a Tira board question via
C<tira.question.ask --voice>, this project's own standing rule for
every card question.

C<--out <path>> writes the synthesized audio there; without it, the
command prints the path of a temp file it created instead (still a
real, playable file - just not at a location the caller chose). Either
way, the printed path is the file to use.

Synthesis failure (C<gtts-cli>/C<ffmpeg> unavailable, or any other
failure inside L<D2TG::TTS/synthesize>) is reported loudly - non-zero
exit, no file ever silently left empty or missing - matching this
skill's existing fail-loud TTS convention (see C<docs/POLICIES.md>'s
"Outbound TTS failure is fatal" section). Does not change
L<D2TG::TTS/synthesize> or L<D2TG::Reply>'s own internal use of it at
all - purely a thin wrapper via the new L<D2TG::TTS/synthesize_to_file>.

=cut
