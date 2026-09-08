#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;

use D2TG::Config;
use D2TG::Lock;

# TGT-111 (user-supplied feature-gap analysis, /tmp/missing2.md item 5):
# the only way to know the poller is actually alive was to reach into
# Tira job metadata (pid/last_output_at) from outside. This command
# answers it directly. Read-only - never touches the lock file, never
# calls D2TG::Lock::acquire (which could evict a genuinely live poller
# just to answer a status question).

my $db_alias;
while (@ARGV) {
    if ( $ARGV[0] eq '--db' || $ARGV[0] eq '-d' ) {
        shift @ARGV;
        $db_alias = eval { D2TG::Config::shift_flag_value( \@ARGV, '--db/-d' ) };
        if ($@) {
            print STDERR $@;
            exit 1;
        }
    }
    else {
        last;
    }
}

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

print "d2tg version: $version\n";
if ( defined $pid ) {
    print "poller: running (pid $pid)\n";
}
else {
    print "poller: not running\n";
}

exit 0;

=head1 NAME

status - report whether the poller is currently running, dispatched as C<d2 tg.status>

=head1 SYNOPSIS

    d2 tg.status [--db <alias> | -d <alias>]

=head1 DESCRIPTION

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

C<--db>/C<-d> match every other C<d2 tg.*> command's own resolution
(L<D2TG::Config/resolve_alias_dir>) - the same storage location the
poller itself would use, so this reports on the right instance.

=cut
