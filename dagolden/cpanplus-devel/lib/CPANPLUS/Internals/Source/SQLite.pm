package CPANPLUS::Internals::Source::SQLite;

use strict;
use warnings;

use base 'CPANPLUS::Internals::Source';

use CPANPLUS::Error;
use CPANPLUS::Internals::Constants;
use CPANPLUS::Internals::Source::SQLite::Tie;

use Data::Dumper;
use DBIx::Simple;
use DBD::SQLite;

use Params::Check               qw[allow check];
use Locale::Maketext::Simple    Class => 'CPANPLUS', Style => 'gettext';

=head1 NAME 

CPANPLUS::Internals::Source::SQLite - SQLite implementation

=cut

{   my $Dbh;
    my $DbFile;

    sub __sqlite_file { 
        return $DbFile if $DbFile;

        my $self = shift;
        my $conf = $self->configure_object;

        $DbFile = File::Spec->catdir( 
                        $conf->get_conf('base'),
                        SOURCE_SQLITE_DB
            );
    
        return $DbFile;
    };

    sub __sqlite_dbh { 
        return $Dbh if $Dbh;
        
        my $self = shift;
        $Dbh     = DBIx::Simple->connect("dbi:SQLite:dbname=" . $self->__sqlite_file );

        #$Dbh->dbh->trace(1);

        return $Dbh;        
    };
}

{   my $used_old_copy = 0;

    sub _init_trees {
        my $self = shift;
        my $conf = $self->configure_object;
        my %hash = @_;
    
        my($path,$uptodate,$verbose,$use_stored);
        my $tmpl = {
            path        => { default => $conf->get_conf('base'), store => \$path },
            verbose     => { default => $conf->get_conf('verbose'), store => \$verbose },
            uptodate    => { required => 1, store => \$uptodate },
            use_stored  => { default  => 1, store => \$use_stored },
        };
    
        check( $tmpl, \%hash ) or return;

        ### if it's not uptodate, or the file doesn't exist, we need to create
        ### a new sqlite db
        if( not $uptodate or not -e $self->__sqlite_file ) {        
            $used_old_copy = 0;

            ### chuck the file
            1 while unlink $self->__sqlite_file;
        
            ### and create a new one
            $self->__sqlite_create_db or do {
                error(loc("Could not create new SQLite DB"));
                return;    
            }            
        } else {
            $used_old_copy = 1;
        }            
    
        ### set up the author tree
        {   my %at;
            tie %at, 'CPANPLUS::Internals::Source::SQLite::Tie',
                dbh => $self->__sqlite_dbh, table => 'author', 
                key => 'cpanid',            cb => $self;
                
            $self->_atree( \%at  );
        }

        ### set up the author tree
        {   my %mt;
            tie %mt, 'CPANPLUS::Internals::Source::SQLite::Tie',
                dbh => $self->__sqlite_dbh, table => 'module', 
                key => 'module',            cb => $self;

            $self->_mtree( \%mt  );
        }
        
        return 1;        
        
    }
    
    sub _standard_trees_completed   { return $used_old_copy }
    sub _custom_trees_completed     { return }
    sub _finalize_trees             { return 1 }
}

sub _add_author_object {
    my $self = shift;
    my %hash = @_;
    my $dbh  = $self->__sqlite_dbh;
    
    my $class;
    my $tmpl = {
        class   => { default => 'CPANPLUS::Module::Author', store => \$class },
        map { $_ => { required => 1 } } 
            qw[ author cpanid email ]
    };

    my $href = do {
        local $Params::Check::NO_DUPLICATES = 1;
        check( $tmpl, \%hash ) or return;
    };
    
    $dbh->query( 
        "INSERT INTO author (". join(',',keys(%$href)) .") VALUES (??)",
        values %$href
    ) or do {
        error( $dbh->error );
        return;
    };
    
    return 1;
 }

sub _add_module_object {
    my $self = shift;
    my %hash = @_;
    my $dbh  = $self->__sqlite_dbh;

    my $class;    
    my $tmpl = {
        class   => { default => 'CPANPLUS::Module', store => \$class },
        map { $_ => { required => 1 } } 
            qw[ module version path comment author package description dslip mtime ]
    };

    my $href = do {
        local $Params::Check::NO_DUPLICATES = 1;
        check( $tmpl, \%hash ) or return;
    };
    
    ### fix up author to be 'plain' string
    $href->{'author'} = $href->{'author'}->cpanid;
    
    $dbh->query( 
        "INSERT INTO module (". join(',',keys(%$href)) .") VALUES (??)",
        values %$href
    ) or do {
        error( $dbh->error );
        return;
    };
    
    return 1;
}

{   my %map = (
        _source_search_module_tree  
            => [ module => module => 'CPANPLUS::Module' ],
        _source_search_author_tree  
            => [ author => cpanid => 'CPANPLUS::Module::Author' ],
    );        

    while( my($sub, $aref) = each %map ) {
        no strict 'refs';
        
        my($table, $key, $class) = @$aref;
        *$sub = sub {
            my $self = shift;
            my %hash = @_;
            my $dbh  = $self->__sqlite_dbh;
            
            my($list,$type);
            my $tmpl = {
                allow   => { required   => 1, default   => [ ], strict_type => 1,
                             store      => \$list },
                type    => { required   => 1, allow => [$class->accessors()],
                             store      => \$type },
            };
        
            check( $tmpl, \%hash ) or return;
        
        
            ### we aliased 'module' to 'name', so change that here too
            $type = 'module' if $type eq 'name';
        
            my $res = $dbh->query( "SELECT * from $table" );
            
            my $meth = $table .'_tree';
            my @rv = map  { $self->$meth( $_->{$key} ) } 
                     grep { allow( $_->{$type} => $list ) } $res->hashes;
        
            return @rv;
        }
    }
}



sub __sqlite_create_db {
    my $self = shift;
    my $dbh  = $self->__sqlite_dbh;
    
    ### we can ignore the result/error; not all sqlite implemantation
    ### support this    
    $dbh->query( qq[
        DROP TABLE IF EXISTS author;
        \n]
     ) or do {
        msg( $dbh->error );
    }; 
    $dbh->query( qq[
        DROP TABLE IF EXISTS module;
        \n]
     ) or do {
        msg( $dbh->error );
    }; 


    
    $dbh->query( qq[
        /* the author information */
        CREATE TABLE author (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            
            author  varchar(255),
            email   varchar(255),
            cpanid  varchar(255)
        );
        \n]

    ) or do {
        error( $dbh->error );
        return;
    };

    $dbh->query( qq[
        /* the module information */
        CREATE TABLE module (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            
            module      varchar(255),
            version     varchar(255),
            path        varchar(255),
            comment     varchar(255),
            author      varchar(255),
            package     varchar(255),
            description varchar(255),
            dslip       varchar(255),
            mtime       varchar(255)
        );
        
        \n]

    ) or do {
        error( $dbh->error );
        return;
    };        
        
    return 1;    
}

1;
