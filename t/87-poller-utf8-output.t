use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use IPC::Open3;
use Symbol qw(gensym);

require D2TG::Poller;
require Fake::Store;

package main;

# TGT-117 (direct observation, live poller log): a real inbound message
# containing non-Latin-1 script (a Cantonese voice-note transcript)
# triggered "Wide character in print at .../D2TG/Poller.pm line 83" -
# D2TG::Poller prints message text to whatever filehandle is currently
# selected as STDOUT, and does nothing itself to open that filehandle
# with a UTF-8 layer; that's cli/poller.pl's job at process startup.

# Extract the exact fix lines from cli/poller.pl (a Codex review finding
# on an earlier draft of this test: a source-text regex check alone
# would pass even if the binmode calls were unreachable/misordered, so
# this actually runs them, verbatim, in a real subprocess).
sub extract_utf8_layer_lines {
    open my $fh, '<', "$Bin/../cli/poller.pl" or die $!;
    local $/;
    my $source = <$fh>;
    my ($block) = $source =~
      /# TGT117-UTF8-LAYER-BEGIN.*?\n(.*?)# TGT117-UTF8-LAYER-END/s;
    die "TGT117-UTF8-LAYER markers not found in cli/poller.pl\n" unless $block;
    return $block;
}

# Run a small Perl program in a real subprocess, capturing stdout/stderr
# separately as raw bytes (no host-perl encoding assumptions). The
# Cantonese text travels via an env var, already UTF-8-encoded to plain
# bytes, so it never has to survive being embedded as wide characters in
# the child's own -e source text / argv.
sub run_perl_capturing {
    my ($code) = @_;
    my ( $in, $out, $err ) = ( gensym, gensym, gensym );
    my $pid = open3( $in, $out, $err, $^X, '-e', $code );
    close $in;
    local $/;
    my $stdout = <$out>;
    my $stderr = <$err>;
    waitpid( $pid, 0 );
    return ( $stdout // '', $stderr // '' );
}

my $utf8_layer_lines = extract_utf8_layer_lines();
my $cantonese        = "\x{5ec9}\x{4ef7}\x{7269}\x{6599}"; # real Cantonese text
my $cantonese_utf8_bytes = do { my $t = $cantonese; utf8::encode($t); $t };

local $ENV{TGT117_TEST_TEXT} = $cantonese_utf8_bytes;

my $child_preamble = q{my $t = $ENV{TGT117_TEST_TEXT};};

# RED: a plain STDOUT/STDERR (no UTF-8 layer at all - what cli/poller.pl
# left them as before this ticket's fix) warns on a wide-character print.
# (The env var arrives as raw bytes with no utf8 flag, same shape as
# text D2TG::Poller decodes from Telegram's own UTF-8 JSON response.)
{
    my $code = qq{use warnings; use utf8; $child_preamble utf8::decode(\$t); print "\$t\\n"; warn "TEST-WARN \$t\\n";};
    my ( $stdout, $stderr ) = run_perl_capturing($code);
    like( $stderr, qr/Wide character in print/,
        'a bare STDOUT with no UTF-8 layer warns on non-Latin-1 text (reproduces TGT-117)' );
}

# GREEN: running the actual TGT117-UTF8-LAYER-BEGIN/END lines extracted
# from cli/poller.pl, verbatim, before the same prints eliminates the
# warning on BOTH streams, and the payload survives as correct UTF-8
# bytes on stdout (not mojibake/replacement characters).
{
    my $code = qq{use warnings; $child_preamble utf8::decode(\$t);\n$utf8_layer_lines\nprint "\$t\\n"; warn "TEST-WARN \$t\\n";};
    my ( $stdout, $stderr ) = run_perl_capturing($code);

    unlike( $stderr, qr/Wide character in print/,
        'cli/poller.pl\'s actual UTF-8-layer lines eliminate the warning on stdout' );
    unlike( $stderr, qr/Wide character in warn/,
        'cli/poller.pl\'s actual UTF-8-layer lines eliminate the warning on stderr too' );

    is( $stdout, "$cantonese_utf8_bytes\n", 'the Cantonese text reaches stdout as correct UTF-8 bytes, not mojibake' );
    like( $stderr, qr/\Q$cantonese_utf8_bytes\E/, 'the Cantonese text reaches stderr as correct UTF-8 bytes too' );
}

# Library-level demonstration: D2TG::Poller::run_once itself does
# nothing to prevent the warning (it relies entirely on the caller's
# filehandle setup) - printing to a filehandle with no layer still warns
# even though the message is still delivered correctly either way.
{
    package Fake::Telegram::Cantonese;
    my $text = "\x{5ec9}\x{4ef7}\x{7269}\x{6599}";
    sub new { return bless {}, shift; }
    sub get_updates {
        my $updates = [ {
            message => {
                message_id => 7,
                chat       => { id => 999 },
                from       => { username => 'owner' },
                text       => $text,
            },
        } ];
        return ( $updates, 8 );
    }

    package main;

    my $tg    = Fake::Telegram::Cantonese->new;
    my $store = Fake::Store->new( allowed => [999] );

    my $out = '';
    open my $out_fh, '>', \$out or die $!;
    my $old_out = select $out_fh;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    D2TG::Poller::run_once( $tg, 42, $store );
    select $old_out;

    ok( ( grep { /Wide character in print/ } @warnings ),
        'D2TG::Poller::run_once itself does nothing to prevent the warning - it is the caller\'s job' );
    like( $out, qr/NEW TG \[999\] owner:/, 'the message is still printed despite the warning' );
}

done_testing();
