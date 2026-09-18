use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;
require Fake::Store;

package main;

sub capture_stdout {
    my ($code) = @_;
    my $out = '';
    open my $fh, '>', \$out or die $!;
    my $old = select $fh;
    $code->();
    select $old;
    close $fh;
    return $out;
}

# TGT-312 (a TGT-311 regression, found via a JOB-003 hourly bug hunt,
# reproduced live in the perl-test container): TGT-311 removed the
# inline content print from a plain-text/successful-voice message's
# own announce line, replacing it with a FETCH WITH command - but that
# command (D2TG::Poller::Format::print_fetch_template) and the
# store-write (D2TG::Poller::Safe::record_message_and_track_offset)
# are both gated on `defined $message_id`. A message genuinely missing
# message_id (a malformed/defensive payload shape - several existing
# fixtures elsewhere in this suite already model its absence, even
# though Telegram's real Bot API always sets it) used to still get
# printed inline before TGT-311; after TGT-311 it vanished completely:
# never shown (TGT-311 removed that), never stored, no FETCH WITH
# command to name it by (no id to reference). Confirmed via live
# reproduction (a direct `perl -Ilib -It/lib -e ...` run, not merely
# read) before this fix.

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 900,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, text => 'no id text message' },
            },
        ],
    );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef ) } );

    like( $out, qr/no id text message/,
        'a text message with no message_id still has its content appear somewhere in stdout - never silently lost' );
    unlike( $out, qr/FETCH WITH/,
        'no FETCH WITH command is printed for it - there is no id to name it by, so the fallback prints content directly instead' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 901,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, voice => { file_id => 'v1' } },
            },
        ],
    );
    my $transcribe_voice = sub { return 'no id transcript content'; };

    my $out = capture_stdout(
        sub { D2TG::Poller::run_once( $tg, undef, undef, transcribe_voice => $transcribe_voice ) } );

    like( $out, qr/no id transcript content/,
        'a voice message with no message_id still has its transcript appear somewhere in stdout - never silently lost' );
    unlike( $out, qr/FETCH WITH/,
        'no FETCH WITH command is printed for it either' );
}

{
    # Sanity: the normal (message_id present) case is completely
    # unaffected - still gets TGT-311's own fetch-command-only
    # treatment, content never printed inline.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 902,
                message   => { message_id => 44, chat => { id => 999 }, from => { username => 'ada' }, text => 'has an id' },
            },
        ],
    );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef ) } );

    unlike( $out, qr/has an id/, 'with message_id present, content is still never printed inline (TGT-311 unaffected)' );
    like( $out, qr/FETCH WITH: d2 tg\.fetch 999 44/, 'and the FETCH WITH command is printed as before' );
}

done_testing();
