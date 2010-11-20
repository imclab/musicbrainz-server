#!/usr/bin/perl
use strict;
use warnings;

use MusicBrainz::Server::Edit::Historic::Base;
{
    no warnings 'redefine';
    *MusicBrainz::Server::Edit::Historic::Base::USE_MOOSE = sub { 0 };
}

use FindBin '$Bin';
use lib "$Bin/../../../lib";

use aliased 'MusicBrainz::Server::Connector';
use aliased 'MusicBrainz::Server::DatabaseConnectionFactory' => 'Databases';

use MusicBrainz::Server::Context;
use MusicBrainz::Server::Data::Utils qw( placeholders );
use Sql;
use Text::CSV_XS;
use Try::Tiny;

my $c = MusicBrainz::Server::Context->create_script_context;

my %skip = map { $_ => 1 } (
    2951, 8052, 21556, 
    21014, 21644,
    33512, 40573, 505233,
    1001582, 1025431, 1062521, 1062536
);

my $conn = Connector->new( database => Databases->get('READWRITE') );
my $csv = Text::CSV_XS->new({ binary => 1 });

my $raw_dbh = $c->raw_dbh;
$raw_dbh->do('COPY edit FROM STDIN');

my $dbh = $conn->dbh;
$dbh->do('CREATE UNIQUE INDEX recording_puid_idx_uniq ON recording_puid (recording, puid)');
$dbh->do('CREATE UNIQUE INDEX puid_idx_puid ON puid (puid)');
$dbh->do('COPY public.moderation_closed TO STDOUT WITH CSV');

my $sql = Sql->new($dbh);
my $raw_sql = Sql->new($raw_dbh);

printf STDERR "Migrating edits (may be slow to start, don't panic)\n";

my ($line, $i) = ('', 0);
while ($dbh->pg_getcopydata($line) >= 0) {
    if(my $fields = $csv->parse($line)) {
        next unless $csv->fields;
        my %row;
        @row{qw(
            id artist moderator tab col type status rowid prevvalue newvalue
            yesvotes novotes depmod automod opentime closetime expiretime language
        )} = $csv->fields;
        
        next if exists $skip{ $row{id} };

        my $historic = $c->model('EditMigration')->_new_from_row(\%row)
            or next;
            
        try {
            $raw_dbh->pg_putcopydata($historic->upgrade->for_copy . "\n");
        }
        catch {
            my $err = $_;
            printf "$line\n";
            $skip{ $historic->id } = 1;
            if ($err =~ /This data is corrupt and cannot be upgraded/) {
                printf "Cannot upgrade #%d: %s", $historic->id, $err;
            }
            else {
                printf STDERR "Could not upgrade %d\n", $historic->id;
                printf STDERR "$err\n";
            }
        }
    }

    printf STDERR "%d\r", $i if $i % 1000 == 0;
    $i++;
}

$raw_dbh->pg_putcopyend;

printf STDERR "Inserting votes\n";
$raw_dbh->do('COPY vote FROM STDIN');
$dbh->do('COPY public.vote_closed TO STDOUT');
$line = '';
while ($dbh->pg_getcopydata($line) >= 0) {
    $raw_dbh->pg_putcopydata($line);
}
$raw_dbh->pg_putcopyend;

printf STDERR "Insert edit notes\n";
$raw_dbh->do('COPY edit_note FROM STDIN');
$dbh->do('COPY public.moderation_note_closed TO STDOUT');
$line = '';
while ($dbh->pg_getcopydata($line) >= 0) {
    $raw_dbh->pg_putcopydata($line);
}
$raw_dbh->pg_putcopyend;

printf STDERR "Removing invalid votes and edit notes\n";
$raw_sql->begin;
$raw_sql->do(
    'DELETE FROM vote WHERE edit IN (' . placeholders(keys %skip) . ')',
    keys %skip
);
$raw_sql->do(
    'DELETE FROM edit_note WHERE edit IN (' . placeholders(keys %skip) . ')',
    keys %skip
);
$raw_sql->commit;

printf STDERR "Nuking rows that point to dead edits...\n";
# The edit migration drops a few edits and this step nukes old votes or edits that point to empty edits
$dbh->do('DELETE FROM vote WHERE id IN (SELECT vote.id FROM vote LEFT JOIN edit ON edit.id = vote.edit WHERE edit.id IS NULL)');
$dbh->do('DELETE FROM edit_note WHERE id IN (SELECT edit_note.id FROM edit_note LEFT JOIN edit ON edit.id = edit_note.edit WHERE edit.id IS NULL)');

printf STDERR "Cleaning up\n";
$dbh->do('DROP INDEX puid_idx_puid');
$dbh->do('DROP INDEX recording_puid_idx_uniq');
