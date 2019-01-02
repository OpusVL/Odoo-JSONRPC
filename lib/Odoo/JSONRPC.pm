package Odoo::JSONRPC;
use strict;
use warnings;
use v5.20;

use Moo;
use Mojo::UserAgent;
use JSON::RPC2::Client;
use Params::ValidationCompiler qw( validation_for );
use failures qw/
    odoo::jsonrpc::rpc::generic
    odoo::jsonrpc::rpc::invalid_response
    odoo::jsonrpc::access
    odoo::jsonrpc::invalid_credentials
/;

#use namespace::autoclean;

our $VERSION = '1';

# ABSTRACT: Allows relatively easy use of the Odoo JSONRPC API

=head1 SYNOPSIS

    use Odoo::JSONRPC;

    my $odoo = Odoo::JSONRPC
        ->connect('https://somehost:80')
        ->login($database, $username, $password);

    # Alternatively
    my $odoo = Odoo::JSONRPC->new(
        host => 'somehost',
        port => 80,
        https => 1
    );
    $odoo->login($database, $username, $password);

    my $data = $rpc->execute($model_name, $method, \%args);

=head1 DESCRIPTION

Connects you to Odoo with a reasonably simple API.

When you C<connect> you receive an object on which you can then call C<login>,
and then any RPC calls you wish via the various methods.

All RPC methods return hashrefs, or throw L<failures> that hopefully explain
what went wrong.

=head1 PROPERTIES

Note that C<rpc_client> and C<ua> are mostly provided for testing purposes.

=head2 host

(Default: localhost)

Provide the hostname to which to connect.

=head2 port

(Default: 8069)

Provide the port to which to connect

=head2 https

(Default: 0)

Set to true to use HTTPS instead of HTTP. This is false by default because we
connect to localhost by default.

=head2 rpc_client

(Default: lazily constructed)

Provide a L<JSON::RPC2::Client> object or we will construct one for you. Since
each client object keeps track of request IDs, you might want to use a single
object for all requests in your system.

=head2 ua

(Default: lazily constructed)

Provide a L<Mojo::UserAgent> object or we will construct one for you. Generally
we advise not passing one in, since each connection is assumed to have
different credentials and therefore a different session.

Our default UA has the C<Content-Type> header set to C<application/json> for all
transactions. If yours doesn't, you might break it.

=head2 user

This is the user hashref returned from Odoo when logging in. The writer is
called C<_user> because you're not supposed to use it.

=head1 METHODS

=head2 new

Constructs a new object. See L<PROPERTIES>.

=cut

has host => (
    is => 'ro',
    default => 'localhost',
);

has port => (
    is => 'ro',
    default => 8069,
);

has https => (
    is => 'ro',
    default => 0
);

has rpc_client => (
    is => 'ro',
    lazy => 1,
    default => sub {
        JSON::RPC2::Client->new
    }
);

has ua => (
    is => 'ro',
    lazy => 1,
    default => sub {
        Mojo::UserAgent->new
            ->inactivity_timeout(0)
            ->request_timeout(30)
            ->tap(on => start => sub {
                my ($ua, $tx) = @_;
                $tx->req->headers->header('Content-Type' => 'application/json');
            })
    }
);

has user => (
    is => 'rw',
    writer => '_user',
);

our %UNIVERSAL_FIELDS = (
    context => {
        optional => 1,
        default => sub {+{}}
    },
    fields => {
        optional => 1,
        default => sub {[]}
    }
);

=head2 connect

Takes a string. Simplifies L<new> by pulling apart a URI containing scheme,
host, and port, and returning a constructed object for you.

Scheme and port are optional but a host is required, as with URIs in general.

With no parameters, this is the same as L<new> with no parameters.

Returns self.

=cut

sub connect {
    my $class = shift;
    my $url = shift;

    my ($scheme, $host, $port) =
        $url =~ m{(?:(https?)://)?(.+)(?::(\d+)?)};

    $class->new(
        host => $host,
        port => $port,
        https => ($scheme eq 'https')
    );
}

=head2 login

Takes database, username, and password. Username is called "login" by Odoo. Logs
the user in or throws some sort of failure. Bad credentials gives
C<failure::odoo::jsonrpc::invalid_credentials>; see L<Mojo::UserAgent> for HTTP
errors.

Returns self.

=cut

sub login {
    my $self = shift;

    my $json_data = $self->rpc_client->call_named(
        'call',
        db => shift,
        login => shift,
        password => shift
    );

    my $tx = $self->ua->post($self->_url('/web/session/authenticate') => $json_data);

    my $obj = $self->_handle_response(
        $tx->result->json,
        context => "login"
    );

    if ($obj->{uid}) {
        $self->_user($obj);
        return $self;
    }
    else {
        failure::odoo::jsonrpc::invalid_credentials->throw({
            msg => "Bad credentials!",
            payload => $obj
        });
    }
}

=head2 fetch_user_fields

Gets the named fields from the current user and adds them to the hashref. Odoo
does not return a complete user object when we log in, so you can use this to
retrieve missing fields.

Returns the user hashref.

=cut

sub fetch_user_fields {
    my $self = shift;
    state $V = validation_for(
        name => __PACKAGE__ . '::fetch_user_fields',
        params => {
            fields => 1
        },
    );

    my %args = $V->(@_);

    my $u = $self->read(
        model => 'res.users',
        ids => [ $self->user->{uid} ],
        fields => $args{fields}
    )->[0];

    $self->user->{@{$args{fields}}} = $u->{@{$args{fields}}};

    return $self->user;
}

=head2 read

Takes named parameters C<model>, C<ids>, C<fields>. C<fields> is an optional
arrayref of field names to return from the model, defaulting to everything if
not provided.

C<ids> is an arrayref of IDs, probably integers. Always returns an arrayref of
results.

=cut

sub read {
    my $self = shift;
    state $V = validation_for(
        name => __PACKAGE__ . '::read',
        params => {
            model => 1,
            ids => 1,
            %UNIVERSAL_FIELDS
        }
    );

    my %args = $V->(@_);

    my $args = [ $args{ids}, $args{fields} // () ];

    $self->call_kw(
        model => $args{model},
        method => 'read',
        args => $args
    );
}

=head2 search

Takes named parameters C<model> and C<domain>, both required, and C<limit> and
C<sort>, which aren't. C<limit> defaults to 80 but C<sort>'s default is handled
by Odoo.

Executes a search against C<model> and returns the results as a list.

=cut

sub search {
    # This is a very thin wrapper around search_read, but I expect it to get
    # thicker.
    my $self = shift;
    state $V = validation_for(
        name => __PACKAGE__ . '::search',
        params => {
            model => 1,
            domain => 1,
            limit => {
                optional => 1,
                default => 80
            },
            sort => {
                optional => 1,
                default => ''
            },
            %UNIVERSAL_FIELDS
        }
    );

    my %args = $V->(@_);

    my $res = $self->search_read(%args);

    return @{ $res->{records} };
}

=head2 find

Returns exactly zero or one result. Works the same as L</search>, except C<sort>
and C<limit> are meaningless here.

Issues a standard Perl warning if the domain returned more than one result,
which technically means you can pass C<< limit => 1 >> if you really want to
silence that, but generally it is advised to pass in a better search domain.

=cut

sub find {
    my $self = shift;
    # let search validate this
    my %args = @_;
    my @res = $self->search(%args);

    if (@res > 1) {
        warn "Find on $args{model} returned more than one result"
    }

    return $res[0];
}

=head1 ODOO CALLS

These can be called as methods but you should probably know what you're doing.
There may be a cleaner interface for public consumption.

Caveat computator.

All methods can take an optional C<context> object, which you can use if you
know why you would want to.

They can also take a C<fields> key, which is an arrayref of fields to be
returned in the output object(s). If omitted, all fields are returned. This can
be nasty if one of those fields is binary file data for some reason.

=head2 call_kw

Takes named parameters C<model>, C<method>, C<args>, and C<kwargs>.

Executes a C<call_kw> request, with variable data. Sets sensible defaults on the
RPC object.

Returns the result of the JSONRPC request, not necessarily the salient data
within it.

=cut

sub call_kw {
    my $self = shift;
    state $V = validation_for(
        name => __PACKAGE__ . '::call_kw',
        params => {
            model => 1,
            method => 1,
            args => 1,
            kwargs => {
                optional => 1,
                default => sub {+{}}
            },
            context => {
                optional => 1
            },
        }
    );

    my %args = $V->(@_);

    my $json = $self->rpc_client->call_named(
        'call', %args
    );

    my $ua_res = $self->ua->post($self->_url('/web/dataset/call_kw') => $json);

    $self->_handle_response($ua_res->result->json, context => "$args{model} - $args{method}");
}

=head2 search_read

Takes named parameters C<model>, C<domain>, C<limit>, C<sort>. C<limit> defaults
to 80, and C<sort> defaults to whatever Odoo wants it to.

C<domain> will be an AoA where each inner array is a search specification.

=cut

sub search_read {
    my $self = shift;
    state $V = validation_for(
        name => __PACKAGE__ . '::search_read',
        params => {
            model => 1,
            domain => 1,
            limit => {
                optional => 1,
                default => 80
            },
            sort => {
                optional => 1,
                default => ''
            },
            context => {
                optional => 1,
                default => sub {+{}}
            },
            fields => {
                optional => 1,
                default => sub {[]}
            }
        }
    );

    my %args = $V->(@_);

    my $json = $self->rpc_client->call_named(
        'call', %args
    );

    my $ua_res = $self->ua->post($self->_url('/web/dataset/search_read') => $json);

    $self->_handle_response($ua_res->result->json, context => "search on $args{model}");
}

=head2 get_accessible_fields

Takes only C<model>.

Helpfully, Odoo throws an AccessError if you try to request an object and you're
not allowed to view one of the fields. You can circumvent it by specifying which
fields you want, and you can use this method to find out which fields you're
allowed to access.

    my $obj = $odoo->read(
        model => 'res.partner',
        ids => [1],
        fields => $odoo->get_accessible_fields( model => 'res.partner' )
    );

Returns the result as a list.

=cut

sub get_accessible_fields {
    my $self = shift;
    state $V = validation_for(
        name => __PACKAGE__ . '::get_accessible_fields',
        params => {
            model => 1,
        }
    );

    my %args = $V->(@_);

    @{ $self->call_kw(
        %args,
        method => 'check_field_access_rights',
        args => ['read', undef]
    ) }
}

=head2 EXCEPTIONS

All exceptions are C<failure> objects, except those that come from
L<Mojo::UserAgent>. If you get one of those, things have gone super wrong.

Remember that failures are hierarchical so you can catch any
C<failure::odoo::jsonrpc> to catch all errors from this distribution.

=head3 C<failure::odoo::jsonrpc::rpc::generic>

Something went wrong with RPC but we don't have a specific error for it.

=head3 C<failure::odoo::jsonrpc::rpc::invalid_response>

Also means things went super wrong. The response from a JSONRPC call did not
contain a valid JSONRPC response. You should check Odoo logs.

=head3 C<failure::odoo::jsonrpc::access>

You have attempted to access a resource restricted to you.

=head3 C<failure::odoo::jsonrpc::invalid_credentials>

Your call to C<login> was not kosher.

=cut

sub _handle_response {
    my $self = shift;
    my $response = shift;
    my %args = @_;

    my $context = $args{context};

    my ($failed, $result, $error, $call) = $self->rpc_client->response( $response );

    if ($failed) {
        failure::odoo::jsonrpc::rpc::invalid_response->throw({
            msg => "RPC call returned invalid response!" . ($context ? " Context: $context" : ""),
            payload => {
                error => $failed,
                call => $call
            }
        });
    }
    if ($error) {
        $self->_throw_specific_exception($error)
        or failure::odoo::jsonrpc::rpc::generic->throw({
            msg => "Error from Oddo",
            payload => {
                error => $error,
                call => $call
            }
        })
    }

    return $result;
}

# TODO: this might want a separate module just to keep this clean
our %ODOO_EXCEPTION_MAP = (
    'odoo.exceptions.AccessError' => 'failure::odoo::jsonrpc::access'
);
sub _throw_specific_exception {
    my $self = shift;
    my $error = shift;

    my $what = $error->{data}->{name};

    return unless $what;

    if (my $e = $ODOO_EXCEPTION_MAP{$what}) {
        $e->throw({
            msg => $error->{data}->{message},
            payload => $error
        });
    }
}

# Not sure it's worth bothering with URI.pm
sub _fullhost {
    my $self = shift;
    my $scheme = $self->https ? 'https' : 'http';
    my $host = $self->host;
    my $port = $self->port;
    "$scheme://$host:$port";
}

sub _url {
    my $self = shift;
    my $path = shift;
    $self->_fullhost . ($path =~ s{^/?}{/}r)
}

1;
