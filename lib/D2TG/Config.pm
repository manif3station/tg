package D2TG::Config;

use strict;
use warnings;

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

=cut
