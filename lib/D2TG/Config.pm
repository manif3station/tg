package D2TG::Config;

use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);

sub token   { return $ENV{D2TG_TOKEN}; }
sub chat_id { return $ENV{D2TG_CHAT_ID}; }

sub require_chat_id_or_warn {
    my $chat_id = chat_id();

    if ( !defined $chat_id || $chat_id eq '' ) {
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

sub state_db_path {
    my (%args) = @_;

    my $skill_root = $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT}
      // $args{default_root}
      // '.';

    my $state_dir = File::Spec->catdir( $skill_root, 'state' );
    make_path($state_dir) unless -d $state_dir;

    return File::Spec->catfile( $state_dir, 'store.sqlite' );
}

1;

=head1 NAME

D2TG::Config - environment-driven configuration for the tg skill

=head1 SYNOPSIS

    use D2TG::Config;

    my $token   = D2TG::Config::token();
    my $chat_id = D2TG::Config::chat_id();

    exit 1 unless D2TG::Config::require_chat_id_or_warn();

=head1 DESCRIPTION

Reads the two environment variables this skill is configured by. There is
no config file and no hardcoded fallback - C<D2TG_TOKEN> and
C<D2TG_CHAT_ID> are read from C<%ENV> only.

=head1 FUNCTIONS

=head2 token

Returns the value of C<D2TG_TOKEN>, or C<undef> if unset.

=head2 chat_id

Returns the value of C<D2TG_CHAT_ID>, or C<undef> if unset.

=head2 require_chat_id_or_warn

Returns true if C<D2TG_CHAT_ID> is set to a non-empty value. Otherwise
prints a warning to C<STDERR> naming the missing variable and returns
false. Callers (e.g. the poller entrypoint) are expected to refuse to
start when this returns false, rather than falling back to a default.

=head2 state_db_path(default_root => $path)

Resolves and returns the path to this skill's SQLite state file
(C<state/store.sqlite>), creating the C<state/> directory if needed.
Resolves the skill root from C<DEVELOPER_DASHBOARD_SKILL_ROOT> if set,
otherwise from the given C<default_root> (callers typically pass
C<File::Spec-E<gt>catdir($Bin, '..')> for this). Both C<cli/poller> and
C<cli/approve> use this so the resolution logic exists in exactly one
place.

=head2 skill_version(default_root => $path)

Reads and returns the C<VERSION=...> line from this skill's own
C<.env> (TGT-036), resolving the skill root the same way
C<state_db_path> does. Dies with a clear message if C<.env> can't be
read at all, or if it has no C<VERSION> line. C<cli/poller> uses this
to detect when a newer version has been installed while it is still
running, so it can restart itself.

=cut
