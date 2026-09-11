use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;

# TGT-193 (found via a scheduled JOB-004 improvement hunt): run_once's 4
# STORE ERROR print blocks (is_allowed x3 - message_reaction, edited_message,
# plain message branches; add_pending x1 - plain message branch) each echoed
# the raw $@ exception text verbatim to STDERR, instead of classifying it via
# the already-established D2TG::Poller::_classify_store_error helper that
# every other D2TG::Store-write error path in this codebase uses
# (_record_message_safe TGT-132/133, persist_offset_safe TGT-166/191,
# D2TG::Reply's _store_write_safe TGT-192). A raw DBI/SQLite exception can
# embed the database file's own real path - the same disclosure risk TGT-133
# established as this project's standard to avoid.

sub capture_stderr {
    my ($code) = @_;
    my $err = '';
    open my $fh, '>', \$err or die $!;
    local *STDERR = $fh;
    $code->();
    close $fh;
    return $err;
}

package Fake::Store::DyingIsAllowed;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        dies_for  => $args{dies_for},
        dies_with => $args{dies_with}
          || "database is locked at /home/mv/.developer-dashboard/skills/tg/.tira/bot.db line 42.\n",
    }, $class;
}

sub is_allowed {
    my ( $self, $id ) = @_;
    die $self->{dies_with}
      if defined $self->{dies_for} && $id == $self->{dies_for};
    return 1;
}

sub add_pending    { return 1; }
sub record_message { return; }
sub get_message     { return; }

package Fake::Store::DyingAddPending;

sub new {
    my ( $class, %args ) = @_;
    return bless { dies_for => $args{dies_for} }, $class;
}

sub is_allowed { return 0; }    # every sender unapproved, forcing add_pending

sub add_pending {
    my ( $self, $id ) = @_;
    die "database is locked at /home/mv/.developer-dashboard/skills/tg/.tira/bot.db line 99.\n"
      if defined $self->{dies_for} && $id == $self->{dies_for};
    return 1;
}

sub record_message { return; }
sub get_message     { return; }

package main;

{
    # is_allowed dies in the plain-message branch.
    my $tg = Fake::Telegram->new(
        [
            { update_id => 930, message => { message_id => 1, chat => { id => 555 }, from => { username => 'dave' }, text => 'hi' } },
        ],
    );
    my $store = Fake::Store::DyingIsAllowed->new( dies_for => 555 );

    my $err = capture_stderr( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $err, qr/STORE ERROR \[555\]: is_allowed failed - database is locked/,
        'plain-message branch: is_allowed failure logs the classified reason' );
    unlike( $err, qr{/home/mv/\.developer-dashboard}, 'the real db_path never leaks into STDERR' );
    unlike( $err, qr/at \S+\.db line \d+/, 'the raw DBI/SQLite exception text is never echoed verbatim - only the classified reason' );
}

{
    # is_allowed dies in the message_reaction branch.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id         => 931,
                message_reaction => {
                    chat         => { id => 556 },
                    message_id   => 7,
                    user         => { username => 'eve' },
                    old_reaction => [],
                    new_reaction => [ { type => 'emoji', emoji => '👍' } ],
                },
            },
        ],
    );
    my $store = Fake::Store::DyingIsAllowed->new( dies_for => 556 );

    my $err = capture_stderr( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $err, qr/STORE ERROR \[556\]: is_allowed failed - database is locked/,
        'message_reaction branch: is_allowed failure logs the classified reason' );
    unlike( $err, qr{/home/mv/\.developer-dashboard}, 'the real db_path never leaks into STDERR' );
    unlike( $err, qr/at \S+\.db line \d+/, 'the raw DBI/SQLite exception text is never echoed verbatim' );
}

{
    # is_allowed dies in the edited_message branch.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id      => 932,
                edited_message => {
                    chat       => { id => 557 },
                    message_id => 8,
                    from       => { username => 'frank' },
                    text       => 'edited text',
                },
            },
        ],
    );
    my $store = Fake::Store::DyingIsAllowed->new( dies_for => 557 );

    my $err = capture_stderr( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $err, qr/STORE ERROR \[557\]: is_allowed failed - database is locked/,
        'edited_message branch: is_allowed failure logs the classified reason' );
    unlike( $err, qr{/home/mv/\.developer-dashboard}, 'the real db_path never leaks into STDERR' );
    unlike( $err, qr/at \S+\.db line \d+/, 'the raw DBI/SQLite exception text is never echoed verbatim' );
}

{
    # add_pending dies in the plain-message branch.
    my $tg = Fake::Telegram->new(
        [
            { update_id => 933, message => { message_id => 9, chat => { id => 558 }, from => { username => 'gina' }, text => 'hi' } },
        ],
    );
    my $store = Fake::Store::DyingAddPending->new( dies_for => 558 );

    my $err = capture_stderr( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $err, qr/STORE ERROR \[558\]: add_pending failed - database is locked/,
        'add_pending failure logs the classified reason' );
    unlike( $err, qr{/home/mv/\.developer-dashboard}, 'the real db_path never leaks into STDERR' );
    unlike( $err, qr/at \S+\.db line \d+/, 'the raw DBI/SQLite exception text is never echoed verbatim' );
}

# A Codex QA-stage review finding: the blocks above only exercised
# _classify_store_error's 'database is locked' branch - its other 3
# branches (busy, readonly, and the unexpected-error fallback) had no
# coverage through these 4 call sites at all. A regression narrowing
# or breaking any of those other branches would still pass every
# assertion above. These 3 blocks close that gap, all through the
# plain-message is_allowed branch (the other 3 branches already prove
# the classifier is reached identically at every call site above -
# this is about the classifier's own remaining ternary arms, not a
# 4th call-site concern).
{
    my $tg = Fake::Telegram->new(
        [
            { update_id => 934, message => { message_id => 10, chat => { id => 559 }, from => { username => 'hank' }, text => 'hi' } },
        ],
    );
    my $store = Fake::Store::DyingIsAllowed->new(
        dies_for  => 559,
        dies_with => "database.tira is busy at /home/mv/.developer-dashboard/skills/tg/.tira/bot.db line 42.\n",
    );

    my $err = capture_stderr( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $err, qr/STORE ERROR \[559\]: is_allowed failed - database is busy/,
        '_classify_store_error\'s busy branch is reached and classified' );
    unlike( $err, qr{/home/mv/\.developer-dashboard}, 'the real db_path never leaks into STDERR' );
}

{
    my $tg = Fake::Telegram->new(
        [
            { update_id => 935, message => { message_id => 11, chat => { id => 560 }, from => { username => 'iris' }, text => 'hi' } },
        ],
    );
    my $store = Fake::Store::DyingIsAllowed->new(
        dies_for  => 560,
        dies_with => "attempt to write a readonly database at /home/mv/.developer-dashboard/skills/tg/.tira/bot.db line 42.\n",
    );

    my $err = capture_stderr( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $err, qr/STORE ERROR \[560\]: is_allowed failed - database is readonly/,
        '_classify_store_error\'s readonly branch is reached and classified' );
    unlike( $err, qr{/home/mv/\.developer-dashboard}, 'the real db_path never leaks into STDERR' );
}

{
    my $tg = Fake::Telegram->new(
        [
            { update_id => 936, message => { message_id => 12, chat => { id => 561 }, from => { username => 'jack' }, text => 'hi' } },
        ],
    );
    my $store = Fake::Store::DyingIsAllowed->new(
        dies_for  => 561,
        dies_with => "disk I/O error at /home/mv/.developer-dashboard/skills/tg/.tira/bot.db line 42.\n",
    );

    my $err = capture_stderr( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $err, qr/STORE ERROR \[561\]: is_allowed failed - an unexpected error/,
        '_classify_store_error\'s fallback branch is reached for an unrecognized error shape' );
    unlike( $err, qr{/home/mv/\.developer-dashboard}, 'the real db_path never leaks into STDERR - even the fallback branch never echoes the raw text' );
    unlike( $err, qr/disk I.O error/, 'the raw exception message itself is never echoed, even for an unrecognized error' );
}

done_testing();
