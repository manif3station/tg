use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

# TGT-202 (found via a scheduled JOB-003 hourly bug hunt):
# D2TG::Config::bot_groups folds D2TG_CHAT_ID/D2TG_TOKEN in as an
# implicit trailing group (TGT-049) even when the CLI already declared
# an identical --chat_id/--bot pair explicitly - producing two
# entries sharing the exact same (chat_id, bot token) pair.
# cli/poller.pl's own @pairs construction then independently polls
# the same bot token twice per cycle, racing its own get_offset/
# set_offset calls for that one bot_key against itself.

my $poller_cli = File::Spec->catfile( $Bin, '..', 'cli', 'poller.pl' );

sub run_capturing_stderr {
    my (@cmd) = @_;
    my $err_file = "/tmp/d2tg-202-stderr.$$";
    my $out_file = "/tmp/d2tg-202-stdout.$$";

    # Bounded wait, not an indefinite one: pre-fix, this refusal does
    # not exist yet, so the poller instead proceeds into a real
    # long-poll against Telegram with a fake token and never exits on
    # its own - this test must still terminate either way. Forks and
    # setpgrp's directly (matching D2TG::Transcribe's own established
    # process-group-kill pattern, TGT-128) rather than a piped-open
    # via a shell, so a timeout can reliably kill poller.pl itself,
    # not just an intermediate shell that leaves it orphaned.
    my $pid = fork();
    die "can't fork: $!" unless defined $pid;

    if ( $pid == 0 ) {
        setpgrp( 0, 0 );
        open STDOUT, '>', $out_file or exit 1;
        open STDERR, '>', $err_file or exit 1;
        exec(@cmd) or exit 1;
    }

    eval { setpgrp( $pid, $pid ) };

    my $reaped;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(10);
        waitpid( $pid, 0 );
        $reaped = 1;
        alarm(0);
    };
    if ( $@ && $@ eq "timeout\n" ) {
        kill( 'KILL', -$pid );
        waitpid( $pid, 0 );
    }

    my $rc  = $reaped ? $? >> 8 : -1;
    my $out = -f $out_file ? do { open my $ofh, '<', $out_file or die $!; local $/; <$ofh> } : '';
    my $err = -f $err_file ? do { open my $efh, '<', $err_file or die $!; local $/; <$efh> } : '';
    unlink $out_file, $err_file;
    return ( $out, $rc, $err );
}

# Unit-level: bot_groups itself must refuse (die) when the CLI's own
# --chat_id/--bot pair exactly duplicates the env-folded pair.
require D2TG::Config;

{
    eval {
        D2TG::Config::bot_groups(
            argv        => [ '--chat_id', '999', '--bot', 'dup-token' ],
            env_chat_id => '999',
            env_token   => 'dup-token',
        );
    };
    like(
        $@,
        qr/duplicate/i,
        'bot_groups refuses when the env-folded pair exactly duplicates an explicit CLI pair'
    );
}

{
    # Regression: genuinely distinct multi-bot groups are unaffected.
    my ( $groups, @rest ) = D2TG::Config::bot_groups(
        argv        => [ '--chat_id', '1234', '--bot', 't1', '--chat_id', '4567', '--bot', 't3' ],
        env_chat_id => undef,
        env_token   => undef,
    );
    is( scalar @$groups, 2, 'distinct multi-bot groups are unaffected - still two groups' );
    is_deeply( $groups->[0]{bots}, ['t1'], 'first group unaffected' );
    is_deeply( $groups->[1]{bots}, ['t3'], 'second group unaffected' );
}

{
    # Regression: the same chat_id with two DIFFERENT bot tokens is a
    # legitimate multi-bot-on-one-chat setup, not a duplicate.
    my ( $groups, @rest ) = D2TG::Config::bot_groups(
        argv        => [ '--chat_id', '1234', '--bot', 't1', '--bot', 't2' ],
        env_chat_id => undef,
        env_token   => undef,
    );
    is( scalar @$groups, 1, 'one chat_id with two distinct tokens is a single, valid group' );
    is_deeply( $groups->[0]{bots}, [ 't1', 't2' ], 'both distinct tokens kept' );
}

# CLI-level (subprocess): the real poller entrypoint surfaces this as
# a startup-time refusal, matching the established pattern (TGT-185's
# own "No bot tokens configured"/"D2TG_CHAT_ID is not set" refusals).
{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'dup-token';
    $ENV{D2TG_CHAT_ID} = '999';

    my ( $out, $rc, $err ) = run_capturing_stderr( $poller_cli, '--chat_id', '999', '--bot', 'dup-token' );

    isnt( $rc, 0, 'a startup-time duplicate-pair refusal exits non-zero' );
    like( $err, qr/duplicate/i, 'refuses naming the duplicate, not silently polling the same bot token twice' );
}

done_testing();
