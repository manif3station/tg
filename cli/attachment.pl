#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;

use D2TG::Config;
use D2TG::Store;

my ( $db_alias, @rest );
( $db_alias, @rest ) = D2TG::Config::extract_db_flag_or_die(@ARGV);
@ARGV = @rest;

my $base_dir = D2TG::Config::resolve_alias_dir_or_die( alias => $db_alias );

eval { D2TG::Config::require_existing_base_dir($base_dir) };
if ($@) {
    print STDERR $@;
    exit 1;
}

if ( @ARGV != 2 || $ARGV[0] !~ /^-?\d+$/ || $ARGV[1] !~ /^\d+$/ ) {
    print STDERR "Usage: d2 tg.attachment <chat_id> <message_id> [--db <alias> | -d <alias>]\n";
    exit 2;
}
my ( $chat_id, $message_id ) = @ARGV;

my $store = D2TG::Store->new(
    db_path => D2TG::Config::state_db_path(
        default_root => File::Spec->catdir( $Bin, '..' ),
        base_dir      => $base_dir,
    ),
    admin_chat_id => D2TG::Config::chat_id(),
);

my $local_path = $store->get_attachment_path( $chat_id, $message_id );
if ( !defined $local_path ) {
    print STDERR "d2 tg.attachment: no attachment recorded for chat $chat_id message $message_id\n";
    exit 1;
}

# TGT-134: a recorded local_path never expires from the database, but
# an existing path pointing at a directory (never legitimately recorded
# by this skill, but worth rejecting explicitly rather than silently
# printing nothing - open() on a directory succeeds, only reading from
# it fails) gets its own message before ever attempting to read it.
# Re-checked on the already-open filehandle below too (a Codex review
# finding: this pre-check and the open() are two separate syscalls, so
# the path could change in between - re-testing -f on the filehandle
# itself, not the path, closes that race for good).
if ( -e $local_path && !-f $local_path ) {
    print STDERR "d2 tg.attachment: the stored attachment path is not a regular file\n";
    exit 1;
}

open my $fh, '<', $local_path
  or do {
    # TGT-134: D2TG::Download::prune_vault runs after every poll cycle
    # and evicts the oldest-mtime attachments once the vault exceeds its
    # byte cap - the file a local_path names can disappear at any later
    # time, even though the database record of it never expires.
    # Classified from open()'s own errno (a Codex review finding: a
    # plain -e/-f pre-check can misreport an unrelated permissions
    # failure - e.g. an unsearchable parent directory - as "pruned",
    # since that also makes -e false without the file actually being
    # gone) rather than a separate existence check.
    if ( $!{ENOENT} ) {
        print STDERR "d2 tg.attachment: the stored attachment no longer exists on disk "
          . "(likely pruned by D2TG::Download::prune_vault's own byte-cap eviction - "
          . "fetching is only reliable for attachments still within the vault's retained set)\n";
    }
    else {
        print STDERR "d2 tg.attachment: cannot open the stored attachment: $!\n";
    }
    exit 1;
  };

# TGT-134 (Codex review finding): re-check on the already-open handle,
# not the path - the pre-open -f check above and this open() are two
# separate syscalls, so the path could in principle change in between
# (e.g. replaced by a directory). Testing -f on $fh itself is race-free.
if ( !-f $fh ) {
    print STDERR "d2 tg.attachment: the stored attachment path is not a regular file\n";
    close $fh;
    exit 1;
}

binmode $fh;
binmode STDOUT;
local $/;
print scalar <$fh>;
close $fh;

exit 0;

=head1 NAME

attachment - stream a downloaded attachment's raw bytes to stdout, dispatched as C<d2 tg.attachment>

=head1 SYNOPSIS

    d2 tg.attachment <chat_id> <message_id> [--db <alias> | -d <alias>]

=head1 DESCRIPTION

C<--db <alias>>/C<-d <alias>> (TGT-051, or C<D2TG_DB=<alias>> as a
fallback) resolves the same way C<d2 tg.poller>'s does - see
L<D2TG::Config/resolve_alias_dir>. The resolved directory (or a
C<TIRA_HOME> fallback) must already exist - refuses to start otherwise
rather than creating it (TGT-090).

TGT-133: looks up C<local_path> for the given C<(chat_id, message_id)>
pair via L<D2TG::Store/get_attachment_path> and writes its raw bytes
to stdout - the real on-disk path is never printed anywhere, matching
this project's own Tira board convention (C<tira.attachment.get>).
Refuses (exit 1, clear STDERR message) if no attachment is recorded for
that pair, or if the stored path can no longer be opened. C<chat_id>
and C<message_id> must both be given and numeric (exit 2, Usage
message, otherwise) - C<chat_id> may be negative (a Telegram group/
channel id).

TGT-134: fetching is not permanently guaranteed - C<local_path> never
expires from the database, but the file it names can be evicted at any
later time by L<D2TG::Download/prune_vault>'s own byte-cap eviction
(run after every poll cycle by C<cli/poller.pl>) if this attachment is
old and nobody re-fetched it (a dedup hit refreshes its mtime, TGT-054,
protecting anything actually re-used). An C<open> failure whose errno is
C<ENOENT> (checked via C<%!>, not a separate pre-check - a plain C<-e>
test can misreport an unrelated permissions failure, e.g. an
unsearchable parent directory, as "gone") names pruning as the likely
cause; a path that exists but isn't a regular file gets its own message
before C<open> is ever attempted, and again immediately after a
successful C<open> (a Codex review finding: the pre-open check and
C<open> are two separate syscalls, so the path could in principle
change in between - re-testing C<-f> on the open filehandle itself,
not the path, closes that race); any other C<open> failure (e.g. a
genuine permissions problem) falls back to the generic message naming
C<$!>.

=cut
