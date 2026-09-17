package D2TG::Config;

use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);
use D2TG::Config::Paths;

sub token      { return $ENV{D2TG_TOKEN}; }
sub chat_id    { return $ENV{D2TG_CHAT_ID}; }
sub owner_name { return $ENV{D2TG_OWNER}; }

sub masked_token {
    my ($token) = @_;

    return '(not set)' unless defined $token && length $token;

    # TGT-138: a token too short to mask usefully (first-4/last-4) used
    # to be returned raw - the exact opposite of what this function
    # exists to prevent. A Codex review caught that <= 8, not < 8, is
    # the correct boundary: an exactly-8-character token's first 4 and
    # last 4 characters are the whole string, so substr(...,0,4).'...'.
    # substr(...,-4) would show every character, just reformatted with
    # '...' in the middle - not masked at all. Real Telegram bot tokens
    # are always far longer than 8 characters, so this path is
    # unreachable in normal operation, but a masking function's one
    # edge case must never leak the full secret regardless.
    return '(short token, not shown)' if length($token) <= 8;

    return substr( $token, 0, 4 ) . '...' . substr( $token, -4 );
}

sub require_chat_id_or_warn {
    my $chat_id = chat_id();

    # TGT-155 (JOB-003 scheduled hourly bug hunt finding, widened after
    # a Codex review finding of its own): chat_id() returns
    # D2TG_CHAT_ID completely raw, with no trimming or validation - any
    # value that isn't Telegram's own canonical integer chat-id shape
    # (bare digits, or a leading '-' for a group/supergroup/channel)
    # previously passed this check as long as it wasn't undef or
    # exactly ''. A whitespace-only value (a copy-paste error, a shell
    # quoting mistake) was the first case found, but the same silent
    # lockout equally applies to any other non-canonical value (leading/
    # trailing whitespace around an otherwise-valid id, e.g. ' 12345 '
    # or "\t12345" - the first fix's own /^\s*$/ check missed exactly
    # this) - Telegram's real numeric chat_id can never string-eq match
    # a mangled one, so the real owner is locked out forever with zero
    # warning. Validates the full expected shape instead of merely
    # excluding known-bad shapes, so no other mangled-but-not-blank
    # variant can slip through the same gap again.
    if ( !defined $chat_id || $chat_id !~ /^-?\d+$/ ) {
        warn "D2TG_CHAT_ID is not set - refusing to start the poller.\n";
        return 0;
    }

    return 1;
}

sub skill_version {
    my (%args) = @_;

    my $skill_root = $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT}
      // $args{default_root}
      // '.';

    my $env_path = File::Spec->catfile( $skill_root, '.env' );

    open my $fh, '<', $env_path
      or die "D2TG::Config::skill_version: cannot read $env_path: $!\n";
    local $/;
    my $env = <$fh>;
    close $fh;

    my ($version) = $env =~ /^VERSION=(\S+)$/m;
    die "D2TG::Config::skill_version: no VERSION line found in $env_path\n"
      unless defined $version;

    return $version;
}

sub changes_summary {
    my (%args) = @_;

    my $skill_root = $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT}
      // $args{default_root}
      // '.';
    my $version = $args{version};

    my $changes_path = File::Spec->catfile( $skill_root, 'Changes' );
    open my $fh, '<', $changes_path or return undef;
    local $/;
    my $changes = <$fh>;
    close $fh;

    # Codex review findings (two rounds): bound the entry at the next
    # actual version header (e.g. "0.92  2026-09-09" - digits, dot,
    # digits, whitespace, an ISO date, end of line), not at any
    # unindented line, nor at any line merely starting with digits and
    # whitespace (a stray "1.2 notes..." prose line inside an entry
    # would otherwise still be mistaken for a header). A bare
    # "(?=\n\S|\z)" would truncate the entry early if it ever contained
    # an unindented continuation/prose line, potentially missing a real
    # bullet further down.
    # TGT-190 (found while investigating TGT-187): this branch used to
    # return undef with zero diagnostic anywhere - a genuine future
    # .env/Changes drift (a manual edit, a version-bump script bug, a
    # merge that updates one but not the other) would silently degrade
    # the version-change restart notice with nothing in the log to say
    # why. Non-fatal STDERR diagnostic only - the return value (undef)
    # is unchanged, matching this project's established non-fatal-
    # degradation pattern (e.g. skill_version_check_safe/
    # persist_offset_safe).
    #
    # A Codex QA-stage review finding: this branch is reached not only
    # by a genuine version-string mismatch, but also by a header line
    # whose version DOES match but is followed by neither whitespace
    # nor any token before the newline (a malformed header, not a
    # wrong version) - so the diagnostic below deliberately does not
    # claim "version mismatch" specifically, only that no entry could
    # be matched for the requested version. Likewise, the second regex
    # below finds the first line ANYWHERE in the file that satisfies
    # the full strict header shape (version + ISO date) - if an
    # earlier, malformed header line precedes it, that earlier line is
    # silently skipped, so the diagnostic names it as "a" recognizable
    # header, not authoritatively "the" file's own top header.
    unless ( $changes =~ /^\Q$version\E\s+\S+\n(.*?)(?=^\d+\.\d+[ \t]+\d{4}-\d{2}-\d{2}[ \t]*$|\z)/ms ) {
        my ($actual_header) = $changes =~ /^(\d+\.\d+[ \t]+\d{4}-\d{2}-\d{2})[ \t]*$/m;

        # A Codex QA-stage review finding: the previous single-string
        # template embedded the "no header found" fallback text
        # directly after the phrase "a recognizable header found in
        # the file:", producing a self-contradictory message
        # ("...found in the file: no recognizable ... found ... at
        # all") whenever $actual_header was the fallback. Branch the
        # wording instead of interpolating a fallback value into
        # phrasing that assumes success.
        my $found_text = defined $actual_header
          ? "a recognizable header found in the file: $actual_header"
          : 'no recognizable version header found in the file at all';
        print STDERR "D2TG::Config::changes_summary: no entry matched for version '$version' ($found_text)\n";
        return undef;
    }
    my $block = $1;

    my ($first_bullet_line) = $block =~ /^\s*-\s*(.+?)\s*$/m;
    return $first_bullet_line;
}

# TGT-260: state_db_path/attachments_dir/lock_path/heartbeat_path/
# write_heartbeat/heartbeat_age moved into D2TG::Config::Paths - thin
# forwarders below so every existing caller (many cli/*.pl scripts and
# lib/ modules, all via fully-qualified D2TG::Config::<name> calls)
# keeps working unchanged. See D2TG::Config::Paths's own POD for the
# full behavior each one documents.
sub state_db_path   { return D2TG::Config::Paths::state_db_path(@_) }
sub attachments_dir { return D2TG::Config::Paths::attachments_dir(@_) }
sub lock_path        { return D2TG::Config::Paths::lock_path(@_) }
sub heartbeat_path    { return D2TG::Config::Paths::heartbeat_path(@_) }
sub write_heartbeat   { return D2TG::Config::Paths::write_heartbeat(@_) }
sub heartbeat_age     { return D2TG::Config::Paths::heartbeat_age(@_) }

# TGT-260: resolve_alias_dir/resolve_alias_dir_or_die/
# require_existing_base_dir/require_existing_base_dir_or_die/
# resolve_self_exec_path moved into D2TG::Config::Paths alongside the
# path helpers above - same forwarder pattern, no behavior change.
sub resolve_alias_dir                { return D2TG::Config::Paths::resolve_alias_dir(@_) }
sub resolve_alias_dir_or_die         { return D2TG::Config::Paths::resolve_alias_dir_or_die(@_) }
sub require_existing_base_dir        { return D2TG::Config::Paths::require_existing_base_dir(@_) }
sub require_existing_base_dir_or_die { return D2TG::Config::Paths::require_existing_base_dir_or_die(@_) }
sub resolve_and_require_base_dir_or_die { return D2TG::Config::Paths::resolve_and_require_base_dir_or_die(@_) }
sub resolve_self_exec_path           { return D2TG::Config::Paths::resolve_self_exec_path(@_) }

sub is_transient_error {
    my ($error) = @_;

    return 1 if $error =~ /timed out/i;
    return 1 if $error =~ /status 5\d\d/;

    # TGT-160 (found via a scheduled hourly bug hunt): Telegram's own
    # Bot API documents 429 ("Too Many Requests") as a designed,
    # expected, retryable rate-limit condition (a response body
    # containing parameters.retry_after) - matches the same "not
    # actually wrong" treatment 5xx/timeout already get. Deliberately
    # does not read parameters.retry_after here - that would require
    # parsing the response body, out of scope for this narrow
    # classification fix.
    return 1 if $error =~ /status 429\b/;

    return 0;
}

sub is_expired_file_error {
    my ($error) = @_;

    # Codex review finding: Telegram's own "file is temporarily
    # unavailable" wording describes a condition that CAN still succeed
    # on a later retry (a real transient server-side hiccup, the same
    # shape as any other getFile failure) - it must not be presented to
    # an operator as permanently unrecoverable. Only "no longer
    # available" and "wrong file_id" are Telegram's genuinely-permanent
    # shapes (an expired or invalid file_id can never resolve).
    return 0 unless defined $error;
    return 1 if $error =~ /file is no longer available/i;
    return 1 if $error =~ /wrong file_id/i;
    return 0;
}


# TGT-173: extracted after this exact SIGALRM-based hard-timeout wrapper
# was found to have identical control flow across D2TG::Telegram and
# D2TG::Download, differing only in how each caller constructed its own
# timeout-message prefix - matches the established shift_flag_value
# (TGT-072) / _classify_store_error (TGT-167) / _format_forwarded_sender
# (TGT-170) / _validate_reply_to_message_id (TGT-171) /
# resolve_alias_dir_or_die (TGT-172) precedent for this shape of
# duplication, this time cross-package. $label is the caller's own
# already-composed die-message prefix (e.g. "D2TG::Telegram sendMessage"
# or "D2TG::Download::download_file"), preserved verbatim so each call
# site's exact die wording is unchanged.
sub _with_hard_timeout {
    my ( $seconds, $label, $coderef ) = @_;

    my $result;
    eval {
        local $SIG{ALRM} = sub { die "$label: request timed out after ${seconds}s\n" };
        alarm($seconds);
        $result = $coderef->();
        alarm(0);
    };
    my $error = $@;
    alarm(0);
    die $error if $error;

    return $result;
}

1;
