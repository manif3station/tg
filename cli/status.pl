#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;

use D2TG::Config;
use D2TG::Lock;
use D2TG::Transcribe;

# TGT-111 (user-supplied feature-gap analysis, /tmp/missing2.md item 5):
# the only way to know the poller is actually alive was to reach into
# Tira job metadata (pid/last_output_at) from outside. This command
# answers it directly. Read-only - never touches the lock file, never
# calls D2TG::Lock::acquire (which could evict a genuinely live poller
# just to answer a status question).
#
# TGT-116: also reports the poller's own heartbeat age - "alive" (pid
# exists) and "working" (still genuinely cycling through poll cycles)
# are different questions, per a real, confirmed incident this session
# where a poller stayed alive and held its lock for 80+ minutes while
# doing nothing at all, silently losing a message.
#
# Codex review finding: the heartbeat is written once per bot/chat pair
# (after each pair's own run_once_safe call), not once per full poll
# cycle - so a single pair can legitimately take as long as
# D2TG::Transcribe's own worst case: its retry-on-timeout ladder
# (medium -> small -> base, TGT-100) can attempt every tier in
# @D2TG::Transcribe::MODEL_TIERS, each bounded at up to
# $D2TG::Transcribe::TIMEOUT_CEILING (TGT-140 - duration-scaled, not a
# flat 300s the way this threshold originally assumed; that flat-300s
# assumption became stale the moment TGT-140 shipped in this same
# session and was never propagated here, a real regression a later
# scheduled bug hunt caught, TGT-147). Derived directly from those two
# constants (never a re-typed literal) so the two can never silently
# drift apart again, with the same ~1.33x safety margin the original
# 1200-over-900 ratio used, so a healthy, actively-transcribing poller
# is never reported STALE.
use constant STALE_THRESHOLD_SECONDS =>
  int( $D2TG::Transcribe::TIMEOUT_CEILING * scalar(@D2TG::Transcribe::MODEL_TIERS) * 4 / 3 );

my ( $db_alias, @rest );
eval { ( $db_alias, @rest ) = D2TG::Config::extract_db_flag(@ARGV) };
if ($@) {
    print STDERR $@;
    exit 1;
}
@ARGV = @rest;

if (@ARGV) {
    print STDERR "Usage: d2 tg.status [--db <alias> | -d <alias>]\n";
    exit 2;
}

my $base_dir = eval { D2TG::Config::resolve_alias_dir( alias => $db_alias ) };
if ($@) {
    print STDERR $@;
    exit 1;
}

eval { D2TG::Config::require_existing_base_dir($base_dir) };
if ($@) {
    print STDERR $@;
    exit 1;
}

my $skill_root = File::Spec->catdir( $Bin, '..' );
my $version    = D2TG::Config::skill_version( default_root => $skill_root );

my $lock_path = D2TG::Config::lock_path(
    default_root => $skill_root,
    base_dir     => $base_dir,
);

my $pid = D2TG::Lock::is_held($lock_path);

my $heartbeat_path = D2TG::Config::heartbeat_path(
    default_root => $skill_root,
    base_dir     => $base_dir,
);
my $heartbeat_age = D2TG::Config::heartbeat_age($heartbeat_path);

print "d2tg version: $version\n";
if ( defined $pid ) {
    print "poller: running (pid $pid)\n";
}
else {
    print "poller: not running\n";
}

if ( !defined $heartbeat_age ) {
    print "heartbeat: never\n";
}
elsif ( $heartbeat_age > STALE_THRESHOLD_SECONDS ) {
    print "heartbeat: ${heartbeat_age}s ago (STALE)\n";
}
else {
    print "heartbeat: ${heartbeat_age}s ago (ok)\n";
}

exit 0;

=head1 NAME

status - report whether the poller is currently running, dispatched as C<d2 tg.status>

=head1 SYNOPSIS

    d2 tg.status [--db <alias> | -d <alias>]

=head1 DESCRIPTION

C<--db>/C<-d> is resolved via L<D2TG::Config/extract_db_flag> (TGT-124,
found via a scheduled improvement-hunt fixing a hand-rolled duplicate
loop), the same shared helper every other C<d2 tg.*> command uses -
this command accepts no other flags, so the fix is a behavior-preserving
consistency cleanup, not a change in what invocations it accepts.

TGT-111 (user-supplied feature-gap analysis): the only way to know the
poller is actually alive used to be reaching into Tira job metadata
(C<pid>/C<last_output_at>) from outside this skill entirely. This
command answers it directly: the installed C<VERSION>, and whether a
live process currently holds the poller's own lock file
(L<D2TG::Lock/is_held>).

Read-only - touches no state, sends no network request, and critically
never calls L<D2TG::Lock/acquire>: doing so to merely answer a status
question would risk evicting a genuinely live poller, per this skill's
own "last one wins" lock policy (TGT-084). C<is_held> only ever sends a
harmless C<kill(0, $pid)> liveness probe (no real signal), and never
touches the lock file itself.

Also reports the poller's own heartbeat age (TGT-116) - "alive" (pid
exists) and "working" (still genuinely cycling through poll cycles) are
different questions, per a real, confirmed incident where a poller
stayed alive and held its lock for 80+ minutes while doing nothing at
all, silently losing a message. C<heartbeat: never> means the poller has
never completed a full poll cycle since this heartbeat file's location
was last cleared; C<heartbeat: <N>s ago (ok)> or C<(STALE)> reports the
age against C<STALE_THRESHOLD_SECONDS> - derived (TGT-147, not a
re-typed literal, after a scheduled bug hunt caught the original fixed
1200s going stale the moment TGT-140 shipped its own duration-scaled
timeout in this same session) from L<D2TG::Transcribe>'s own
C<$TIMEOUT_CEILING> and C<@MODEL_TIERS> constants
(C<$TIMEOUT_CEILING * scalar(@MODEL_TIERS) * 4/3>, currently 14400s/4h)
- kept safely above the worst-case time a single bot/chat pair's own
poll cycle can legitimately take, including a slow voice
transcription's full retry ladder at its new, longer per-tier budget.

C<--db>/C<-d> match every other C<d2 tg.*> command's own resolution
(L<D2TG::Config/resolve_alias_dir>) - the same storage location the
poller itself would use, so this reports on the right instance.

=cut
