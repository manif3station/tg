#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $skill_root  = File::Spec->catdir( $Bin, '..' );
my $skills_path = File::Spec->catfile( $skill_root, 'SKILLS.md' );
my $commands_path = File::Spec->catfile( $skill_root, 'docs', 'commands.md' );

print _slurp($skills_path);
print "\n" . ( '-' x 72 ) . "\n\n";
print _slurp($commands_path);

sub _slurp {
    my ($path) = @_;

    open my $fh, '<', $path
      or die "d2 tg.help: cannot read $path: $!\n";
    local $/;
    my $content = <$fh>;
    close $fh;

    return $content;
}

=head1 NAME

help - print this skill's own onboarding runbook and command reference, dispatched as C<d2 tg.help>

=head1 SYNOPSIS

    d2 tg.help

=head1 DESCRIPTION

Live user request (TGT-089): an agent unfamiliar with this skill has no
way to read its own documentation via a C<d2 tg.*> command - it would
otherwise need to already know the skill's install directory on disk
(C<~/.developer-dashboard/skills/tg/>) to find C<SKILLS.md>/
C<docs/commands.md> directly, which defeats the purpose of a
self-describing CLI tool.

Prints C<SKILLS.md> (the onboarding runbook: what this skill is, install
prep, config, an end-to-end onboarding test, and how to register the
poller as a Tira monitor job) in full, then a plain divider line, then
C<docs/commands.md> (the full C<d2 tg.*> command reference) in full.
Both are resolved relative to this script's own location via
C<FindBin>, the same pattern every other C<cli/*> script already uses to
find C<lib/> - so this works from any install location, not just this
development checkout.

Takes no arguments and requires no environment variables (TGT-059's
mandatory C<--db>/C<-d>/C<D2TG_DB> storage-location guard does not apply
here - this command touches no state, network, or credentials at all, it
only reads two static files that ship with the skill). Dies with a clear
error naming the missing file if either C<SKILLS.md> or
C<docs/commands.md> is absent - this should never happen in a real
install, but a clear failure beats a silent partial dump.

=cut
