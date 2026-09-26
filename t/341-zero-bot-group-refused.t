use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

# TGT-341 (found via a live, scheduled JOB-003 hourly bug hunt):
# cli/poller.pl's only guard against a misconfigured --chat_id group
# (the "No bot tokens configured" refusal) only fires when @pairs is
# ENTIRELY empty - i.e. every group has zero bots. A MIXED config (one
# --chat_id group with a real bot, another with none - e.g. a
# copy-paste mistake forgetting --bot after a --chat_id) passes this
# guard silently: the zero-bot group contributes zero entries to
# @pairs (never polled, never admin-seeded) while the other group(s)
# work normally, visible only by carefully reading the multi-bot
# startup banner's "chat_id NNN: 0 bot(s) ()" line, not refused.

my $poller_cli = File::Spec->catfile( $Bin, '..', 'cli', 'poller.pl' );

sub run_capturing_stderr {
    my (@cmd) = @_;
    my $err_file = "/tmp/d2tg-341-stderr.$$";
    my $out_file = "/tmp/d2tg-341-stdout.$$";

    # Bounded wait, not an indefinite one - matching t/202's own
    # established pattern: pre-fix, this refusal does not exist yet, so
    # the poller instead proceeds into a real long-poll against
    # Telegram with a fake token and never exits on its own.
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

# Unit-level: bot_groups itself is unchanged - it still legitimately
# parses a zero-bot group with no error (the ambiguity is only
# resolvable at the caller level: is this ever a valid shape? cli/
# poller.pl says no).
require D2TG::Config;
require D2TG::Config::Flags;

{
    my ( $groups, @rest ) = D2TG::Config::Flags::bot_groups(
        argv        => [ '--chat_id', '111', '--chat_id', '222', '--bot', 'realtoken' ],
        env_chat_id => undef,
        env_token   => undef,
    );
    is( scalar @$groups, 2, 'bot_groups itself still parses both groups (unchanged, no error)' );
    is_deeply( $groups->[0]{bots}, [], 'the first group genuinely has zero bots' );
    is_deeply( $groups->[1]{bots}, ['realtoken'], 'the second group has its one bot' );
}

# CLI-level (subprocess): the real poller entrypoint must refuse this
# mixed shape at startup, matching the established "No bot tokens
# configured" refusal style (TGT-185) - just scoped per-group, not
# only to the all-empty case.
{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    delete $ENV{D2TG_TOKEN};
    delete $ENV{D2TG_CHAT_ID};

    my ( $out, $rc, $err ) =
      run_capturing_stderr( $poller_cli, '--chat_id', '111', '--chat_id', '222', '--bot', 'realtoken' );

    isnt( $rc, 0, 'a startup-time zero-bot-group refusal exits non-zero' );
    like( $err, qr/111/, 'the refusal names the specific chat_id (111) that has zero bots configured' );
    unlike( $err, qr/^\z/, 'a real message was printed, not a silent non-zero exit' );
}

# Regression: the existing all-empty-groups case must still refuse the
# same way it always has.
{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    delete $ENV{D2TG_TOKEN};
    delete $ENV{D2TG_CHAT_ID};

    my ( $out, $rc, $err ) = run_capturing_stderr( $poller_cli, '--chat_id', '111' );

    isnt( $rc, 0, 'the pre-existing all-empty-groups case still refuses (regression check)' );
    like( $err, qr/no bot tokens configured/i, 'still names the original all-empty refusal message' );
}

# Regression: a genuinely well-formed multi-bot config must still start
# cleanly past this new guard (it will still fail later trying to
# reach Telegram with a fake token, but must NOT be refused by this
# specific guard).
{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    delete $ENV{D2TG_TOKEN};
    delete $ENV{D2TG_CHAT_ID};

    my ( $out, $rc, $err ) =
      run_capturing_stderr( $poller_cli, '--chat_id', '111', '--bot', 't1', '--chat_id', '222', '--bot', 't2' );

    unlike( $err, qr/zero bot|has no bot/i, 'a genuinely well-formed multi-bot config is never refused by this new guard' );
}

done_testing();
