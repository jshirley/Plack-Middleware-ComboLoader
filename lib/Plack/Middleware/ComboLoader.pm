package Plack::Middleware::ComboLoader;
use strict;
use warnings;

use parent qw(Plack::Middleware);

use Carp 'carp';

use Plack::Request;
use Path::Class;
use Plack::MIME;
use Try::Tiny;
use HTTP::Throwable::Factory qw(http_throw http_exception);

use Plack::App::File;

# ABSTRACT: Handle combination loading and processing of on-disk resources.

__PACKAGE__->mk_accessors(qw( roots patterns save expires));

=head1 SYNOPSIS

    use Plack::Builder;

    builder {
        enable "ComboLoader",
            roots => {
                'yui3'         => 'yui3/',
                'yui3-gallery' => 'yui3-gallery/',
                'our-gallery'  => 'our-gallery/',
                # Or, if you want to run each file through something:
                '/static/css' => {
                    path      => 'static/css',
                    processor => sub {
                        # $_ isa Path::Class::File object
                        # It is much, much better to minify as a build process
                        # and not on demand.
                        CSS::Minifier::minify( input => $_->slurp );
                        # This method returns a *string*
                    }
                }
            },
            # Optional parameter to save generated files to this path:
            # If the file is there and it's not too old, it gets served.
            # If it is too old (the expires below), it will be regenerated.
            save => 'static/combined',
            expires => 86400, # Keep files around for a day.
        $app;
    };

=head1 DESCRIPTION

This is (another) combination loader for static resources. This is designed to
operate with the YUI3 Loader Service.

You can specify multiple points, and if all files are of the same type it sets
the mime-type and all proper caching headers for the browser.

The incoming requests will look like:

    http://my.cdn.com/rootName?3.4.1/build/module/module.js&3.4.1/build/module2/module2.js

The rootName specifies the path on disk, and each query arg is a file under the
path.

=head1 PROCESSING FILES

I highly recommend doing minifying and building prior to any serving. This way
files stay on disk, unmodified and perform better.  If, however, you want to
do any processing (like compiling templates into JavaScript, a la Handlebars)
you can do that.

Use the C<processor> option, you can munge your files however you wish.

The sub is passed in a L<Path::Class::File> object, and should return a string.

Whatever return value is appended to the output buffer and sent to the client.

=cut

sub call {
    my ( $self, $env ) = @_;

    my $roots = $self->roots || {};
    unless ( ref($roots) eq 'HASH' ) {
        carp "Invalid root configuration, roots must be a hash ref of names to paths\n";
    }

    my $path_info = $env->{PATH_INFO};
    $path_info =~ s/^\///;
    if ( exists $roots->{$path_info} or exists $roots->{"/$path_info"} ) {
        my $path = $roots->{$path_info} || $roots->{"/$path_info"};
        my $config = {};
        if ( ref $path eq 'HASH' ) {
            $config = $path;
        } else {
            $config->{path} = $path;
        }
        my $dir = Path::Class::Dir->new($config->{path});
        unless ( -d $dir ) {
            http_throw( InternalServerError => {
                message =>"Invalid root directory for `/$path_info`: $dir does not exist"
            });
        }

        my @resources = split('&', $env->{QUERY_STRING});
        my $req = Plack::Request->new( $env );
        my $res = $req->new_response;
        $res->status(200);
        my $content_type = 'plain/text';

        if ( $self->save ) {
            my $save_dir = Path::Class::Dir->new($self->save)->subdir($path_info);
            my $f = $save_dir->file( URI::Escape::uri_escape($env->{QUERY_STRING}) );
            my $stat = $f->stat;
            my $expiry = $self->expires || 86400;
            if ( $stat && $stat->mtime + $expiry > time ) {
                my ( $content_type, @buffer ) = $f->slurp;
                $res->header('Last-Modified'  => HTTP::Date::time2str( $stat->mtime ));
                $res->header('X-Generated-On' => HTTP::Date::time2str( $stat->mtime ));
                $res->content_type($content_type);
                $res->content(join("", @buffer));
                return $res->finalize;
            }
        }

        my $buffer        = '';
        my $last_modified = 0;
        my %seen_types    = ();

        foreach my $resource ( @resources ) {
            my $f = $dir->file($resource);
            my $stat = $f->stat;
            unless ( defined $stat ) {
                http_throw( BadRequest => {
                    message => "Invalid resource requested: `$resource` is not available."
                });
            }

            $seen_types{ Plack::MIME->mime_type($f->basename) || 'text/plain' } = 1;
            # Set the last modified to the most recent file.
            $last_modified = $stat->mtime if $stat->mtime > $last_modified;

            if ( exists $config->{processor} ) {
                local $_ = $f;
                try { $buffer .= $config->{processor}->($f); }
                catch {
                    http_throw( InternalServerError => {
                        message => "Processing failed for `$resource`: $_"
                    });
                };
            } else {
                $buffer .= $f->slurp;
            }
        }
        if ( $self->save ) {
            my $save_dir = Path::Class::Dir->new($self->save)->subdir($path_info);
            $save_dir->mkpath;
            my $f = $save_dir->file( URI::Escape::uri_escape($env->{QUERY_STRING}) );
            my $fh = $f->openw;
            print $fh "$content_type\n";
            print $fh $buffer;
            $fh->close;
        }

        # We only encountered one content-type, rejoice, for we can set one
        # sensibly!
        if ( scalar keys %seen_types == 1 ) {
            ( $content_type ) = keys %seen_types;
        }
        $res->content_type($content_type);
        $res->header('Last-Modified' => HTTP::Date::time2str( $last_modified ) );
        $res->content($buffer);
        return $res->finalize;
    }

    $self->app->($env);
}

1;
