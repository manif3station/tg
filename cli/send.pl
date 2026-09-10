#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;

use D2TG::Config;
use D2TG::Telegram;
use D2TG::Reply;

# TGT-103 (user-supplied feature-gap analysis, /tmp/missing.md item 1):
# the old ~/skills/tg blueprint had two dedicated senders for pushing a
# local file to Telegram as a photo or document message - this skill had
# no outbound-media primitive at all until this command. Thin CLI
# wrapper around D2TG::Telegram::send_photo/send_document.

my $bot_token;
my $caption;
my $reply_to_message_id;

# TGT-124 (found via a scheduled improvement-hunt): --db/-d is
# extracted first, scanning the ENTIRE argument list (matching every
# other cli/*.pl script's own use of extract_db_flag) - unlike the
# --bot/--caption/--reply-to-message-id loop below, which is only ever
# recognized before the two positional arguments (chat_id, file_path),
# --db/-d must not have that same position restriction, since a caller
# reasonably expects flag order to be interchangeable.
#
# Accepted, inherited limitation (a Codex review raised it): since this
# scans the whole argv for a literal '--db'/'-d' token BEFORE the
# --caption/--reply-to-message-id loop below runs, a contrived
# invocation like `--caption --db 123 file.jpg` no longer fails with
# "--caption requires a value" (its pre-TGT-124 behavior) - it now
# extracts '--db 123' as an attempted db alias instead, refusing with
# "Unknown --db/-d alias '123'" if 123 isn't registered. Both before and
# after, this safely refuses rather than silently misbehaving (no send
# happens, no wrong caption is used) - only the specific error message
# differs for this unlikely, essentially-nonsensical input shape. This
# ambiguity is inherent to extract_db_flag's own scan-the-whole-argv
# design, already shared by every other cli/*.pl script that uses it;
# giving send.pl its own different, position-aware extraction here would
# defeat the entire point of this ticket (consistency with those 7
# scripts) for a scenario with no legitimate real usage.
my ( $db_alias, @after_db );
eval { ( $db_alias, @after_db ) = D2TG::Config::extract_db_flag(@ARGV) };
if ($@) {
    print STDERR $@;
    exit 1;
}
@ARGV = @after_db;

while (@ARGV) {
    if ( $ARGV[0] eq '--bot' ) {
        if ( @ARGV >= 2 ) {
            ( $bot_token, @ARGV ) = D2TG::Reply::extract_bot_flag(@ARGV);
        }
        else {
            shift @ARGV;
        }
    }
    elsif ( $ARGV[0] eq '--caption' ) {
        shift @ARGV;
        $caption = eval { D2TG::Config::shift_flag_value( \@ARGV, '--caption' ) };
        if ($@) {
            print STDERR $@;
            exit 1;
        }
    }
    elsif ( $ARGV[0] eq '--reply-to-message-id' ) {
        shift @ARGV;
        $reply_to_message_id = eval { D2TG::Config::shift_flag_value( \@ARGV, '--reply-to-message-id' ) };
        if ($@) {
            print STDERR $@;
            exit 1;
        }
    }
    else {
        last;
    }
}

my $base_dir = D2TG::Config::resolve_alias_dir_or_die( alias => $db_alias );

eval { D2TG::Config::require_existing_base_dir($base_dir) };
if ($@) {
    print STDERR $@;
    exit 1;
}

my ( $chat_id, $file_path, @extra ) = @ARGV;

# Codex review finding: --caption/--reply-to-message-id are only ever
# recognized in the LEADING position (before chat_id/file_path, in the
# same loop as --db/--bot above) - any argument left over after the two
# required positionals must refuse loudly rather than being silently
# dropped. Before this fix, `d2 tg.send 42 img.jpg --caption "hi"` sent
# the file with no caption at all and no error, exactly the "silently
# ignored, not refused" danger TGT-107 exists to close for cli/poller.pl.
if ( !defined $chat_id
    || $chat_id !~ /^-?\d+$/
    || !defined $file_path
    || !length $file_path
    || @extra
    || ( defined $reply_to_message_id && $reply_to_message_id !~ /^\d+$/ ) )
{
    print STDERR "Usage: d2 tg.send [--db <alias> | -d <alias>] [--bot <token>] [--caption <text>] [--reply-to-message-id <id>] <chat_id> <file_path>\n";
    exit 2;
}

# Codex review finding: -e also accepts directories, FIFOs, devices, and
# sockets - a FIFO could block indefinitely inside _send_file's blocking
# read, and a directory is not a valid upload at all. -f requires a
# genuine regular file.
if ( !-f $file_path ) {
    print STDERR "d2 tg.send: file not found: $file_path\n";
    exit 1;
}

# Decided by file extension, not content sniffing - simple and matches
# what Telegram itself expects (sendPhoto renders inline for common
# image formats; everything else works fine as sendDocument regardless).
my ($ext) = $file_path =~ /\.([^.]+)$/;
my $is_photo = defined $ext && lc($ext) =~ /^(?:jpe?g|png|gif|webp)$/;

my $telegram = D2TG::Telegram->new( token => $bot_token // D2TG::Config::token() );

my %opts;
$opts{caption}              = $caption              if defined $caption;
$opts{reply_to_message_id}  = $reply_to_message_id  if defined $reply_to_message_id;

my $result = eval {
    $is_photo
      ? $telegram->send_photo( $chat_id, $file_path, %opts )
      : $telegram->send_document( $chat_id, $file_path, %opts );
};
if ($@) {
    print STDERR $@;
    exit 1;
}

print "Sent " . ( $is_photo ? 'photo' : 'document' ) . " to $chat_id\n";

=head1 NAME

send - push a local file to a chat as a photo or document, dispatched as C<d2 tg.send>

=head1 SYNOPSIS

    d2 tg.send [--db <alias> | -d <alias>] [--bot <token>] [--caption <text>] [--reply-to-message-id <id>] <chat_id> <file_path>

=head1 DESCRIPTION

TGT-103 (user-supplied feature-gap analysis): the old C<~/skills/tg>
blueprint had two dedicated senders (one for images, one for any other
file type) that took a local file path and pushed it to Telegram - this
skill had no outbound-media primitive at all until this command. Thin
wrapper around L<D2TG::Telegram/send_photo> and
L<D2TG::Telegram/send_document>.

Whether the file is sent as a photo (renders inline in Telegram) or a
document (downloadable) is decided by its extension: C<.jpg>/C<.jpeg>/
C<.png>/C<.gif>/C<.webp> (case-insensitive) send as a photo; everything
else sends as a document. No content sniffing - Telegram itself accepts
any file type via C<sendDocument> regardless.

C<--db>/C<-d> is resolved via L<D2TG::Config/extract_db_flag> and may
appear anywhere in the argument list, not just before the other flags/
positionals (TGT-124, found via a scheduled improvement-hunt: the
previous hand-rolled loop stopped at the first non-flag token, so
C<d2 tg.send E<lt>chat_idE<gt> E<lt>fileE<gt> --db myalias> refused with
a bogus Usage error instead of resolving C<--db> from its trailing
position - now matches every other C<d2 tg.*> command's own behavior).
C<--bot>, C<--caption>, and C<--reply-to-message-id> may still appear in
any order before C<chat_id>/C<file_path> (unchanged). C<--caption> is
optional free text attached to the sent photo/document.
C<--reply-to-message-id> (numeric) threads the send under an existing
Telegram message, matching C<d2 tg.reply>'s own flag. C<--bot> matches
C<d2 tg.reply>'s own leading-flag shape and validation
(L<D2TG::Config/shift_flag_value>). Any argument left over after
C<chat_id>/C<file_path> refuses with C<Usage> (exit 2) rather than being
silently dropped (a real gap caught by Codex review before shipping -
previously C<--caption>/C<--reply-to-message-id> given I<after>
C<chat_id file_path> were accepted syntactically and then silently
ignored, sending the file with neither).

C<chat_id> is validated as numeric and C<file_path> must exist on disk
as a genuine regular file (C<-f>, not merely C<-e> - a Codex review
finding: C<-e> alone would also accept a directory, FIFO, device, or
socket, any of which is not a valid upload, and a FIFO could block
C<_send_file>'s read indefinitely) before any network call is attempted
- a missing or non-regular-file path refuses with a clear message
rather than an opaque Telegram API error.

=cut
