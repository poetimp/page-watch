#!/usr/bin/perl -w
#------------------------------------------------------------------------------------------
#
# Program: page_watch.pl
# Author:  Paul Lemmons
# Date:    10/09/2006
# Description:
#          This program watches web pages and reports changes. To do this it keeps a local
#          cache of the page. The page can be checked for changes in its entirety or only
#          the links contained within the page.
#
#          The configuration file for this program may either reside in a default location
#          or may be specified on the comand line.
#
#          The default location is: ~/.page-watch.cf
#
#          To specify the configuration file on the command line use the -cf option:
#
#          Syntax: page-watch.pl [-cf config.file]
#
#------------------------------------------------------------------------------------------
#  To-Do
#------------------------------------------------------------------------------------------
#
# - Add a real configuration file (done 10/11/06)
# - consider how to user "last-mdified' server request
#
#------------------------------------------------------------------------------------------
#  C H A N G E   H I S T O R Y
#------------------------------------------------------------------------------------------
# 10/10/2006
# - Added "headers" as a watchType option (value is suspect)
# - Added support for defaults for notify and page watch type
# - Moved some code around so as to not do unneeded work
# - Moved some hard coded values from sendmail call to configuration variables
#
# 10/11/2006
# - Added configuration file support
# - Added "strict" to keep me honest with variables and force me to comment them
#------------------------------------------------------------------------------------------

use WWW::Mechanize;
use Mail::Sendmail;
use strict;

#====================================================================================================
# Subroutine prototypes
#====================================================================================================
sub write_page_data($);
sub get_headers($);
sub loadConfiguration($);

#====================================================================================================
# Global Variables
#====================================================================================================
#  Filled by loadConfiguration() and used by various subroutines
my %pageList     = ();  # List of pages to watch. Will contain URL's
my %watchTypeList= ();  # Keyed the same as pageList, type of comparison to make
my %notifyList   = ();  # Keyed the same as pageList, Who to notify
my $emailFrom;          # Who the notificationemail should appear to be from
my $smtpServer;         # The name of the SMPT server

# defined in main and Used by write_page_data();
my $lwp;                # reference to WWW::LWP object

#====================================================================================================
# Misc Variables
#====================================================================================================
my $cacheFile;          # The name of the ache File
my $confFile;           # The name of the configuration file
my $emailTo;            # Who to notify
my %mail;               # hash to contain email message. used by sendmail object
my $mech;               # reference to an WWW::Mechanize object
my $nick;               # The nickname of the page being processed
my $now;                # Today's date and time
my $page;               # The nick name for a page
my $pageDB;             # The array of page nick names
my $testFile;           # A temp file used to compare against current file
my $diff;               # The differences

#====================================================================================================
# Load the configuration file. Default cile is in home directory ~/page-watch.cf. This can be
# overridden by using the -cf option on the command line
#====================================================================================================
if (defined($ARGV[0]))
{
   if ($ARGV[0] =~ /-cf/i and defined($ARGV[1]))
   {
      $confFile = $ARGV[1];
   }
   elsif (!defined($ARGV[1]))
   {
      die "Missing configuration file name on -cf parameter\n";
   }
   else
   {
      die "unrecognized parameter: ".$ARGV[0]."\n";
   }
}
else
{
   $confFile='~/.page-watch.cf';
}

loadConfiguration($confFile);

#====================================================================================================
# The real work starts here. For each page identified in %pageList, check to see if it has changed
#====================================================================================================
while (($nick,$page) = each(%pageList))
{
   #================================================
   # Create object to access page with
   #================================================

   $mech = WWW::Mechanize->new(autocheck => 1,
                               quiet     => 1,
                              );

   #================================================
   # Create the cache directory if needed
   #================================================

   if (-e "$pageDB/$nick" and !(-d "$pageDB/$nick"))
   {
      die "$pageDB/$nick must be a directory"
   }
   elsif (!(-e "$pageDB/$nick"))
   {
      mkdir("$pageDB/$nick",0770) or die "Unable to create cached page directory: $pageDB/$nick, $!\n";
   }

   $cacheFile = "$pageDB/$nick/cache";
   $testFile  = "$pageDB/$nick/test";

   #================================================
   # Get the page contents
   #================================================
   $lwp     = $mech->get($page);

   #================================================
   # If the cache file already exists then compare
   #================================================
   if (-e "$cacheFile")
   {
      print "Checking $nick against currently cached page information... ";

      write_page_data($testFile);

      $diff = `diff $testFile $cacheFile`;
      if ($? == 0)
      {
         print "Files are identical\n";
         unlink("$testFile");
      }
      else
      {
         print "Files are different\n";
         chomp($now = `date +%m%d%y-%H%M`);
         rename($cacheFile,$cacheFile."-$now") or die "Unable to rename cache file: $!\n";
         rename($testFile ,$cacheFile)         or die "Unable to rename html file: $!\n";
         if (defined($notifyList{$nick}))
         {
            $emailTo = $notifyList{$nick};
         }
         else
         {
            $emailTo = $notifyList{'default'};
         }

         $mail{'Smpt'}         = $smtpServer;
         $mail{'To'}           = $emailTo;
         $mail{'From'}         = $emailFrom;
         $mail{'Subject'}      = 'Page Changed';
         $mail{'CONTENT-TYPE'} = 'text/html; charset="us-ascii"';
         $mail{'Message'}      = '<html><body><font face="Arial">'
                                 .'<h1>Page Watcher Notification</h1>'
                                 .'<b>The page you are watching has changed: </b>'
                                 ."<a href=\"$page\">$nick</a>"
                                 .'</font>'
                                 .'<p><pre>'.$diff.'</pre></p>'
                                 .'</body></html>';
         (sendmail %mail) || print "Send failed: $Mail::Sendmail::error\n";
      }
   }
   #================================================
   # If cache file does not exist then simply create
   # it. The next time this program runs it will be
   # used to compare against.
   #================================================
   else
   {
      write_page_data($cacheFile);

      print "Successfully performed initial cache of $nick web page\n";
   }
}
#====================================================================================================
# Subroutine to write a file that will conatins either the whole page or just the links
#====================================================================================================
sub write_page_data($)
{
   #================================================
   # Get the filename from parm and open it for output
   #================================================
   my $fileName = shift;   # The name of the file to write
   my $watchType;          # The type of comparison to be done
   my $link;               # Reference to a WWW::Link object
   my @links;              # An array of $link
   my $url;                # The URL
   my %urlList;            # The array if URL's

   open  (DAT,">$fileName") or die "Unable to open cache file $fileName, $!\n";

   #================================================
   # Write only the unique links to file. Sort them
   # too. This way it does not matter if the page
   # author moves things around or duplicates links.
   #================================================
   if (defined($watchTypeList{$nick}))
   {
      $watchType = $watchTypeList{$nick};
   }
   else
   {
      $watchType = $watchTypeList{'default'};
   }
   if ($watchType =~ /links/i)
   {
      #================================================
      # get the list of links on the page
      #================================================
      @links = $mech->links();
      #================================================
      # Put the link names in a hash so the list will
      # only contain unique url's
      #================================================
      foreach $link (@links)
      {
         $urlList{$link->url()} = 1;
      }
      #================================================
      # Go through the list and output it sorted to a file
      #================================================
      foreach $url (sort(keys(%urlList)))
      {
         print DAT "$url\n";
      }
   }
   #================================================
   # Doing the whole page? That is just too easy
   #================================================
   elsif ($watchType =~ /page/i)
   {
      print  DAT $mech->content;
   }
   #================================================
   # Doing just the headers? That is easy too!
   #================================================
   elsif ($watchType =~ /headers/i)
   {
      print  DAT get_headers($lwp);
   }
   #================================================
   # Hmmmm somebody is not reading the instructions!
   #================================================
   else
   {
      die "ERROR: Invalid watch type! ".$watchTypeList{$nick}."\n";
   }

   #================================================
   # say goodnight Gracie...
   #================================================
   close (DAT);
}
#====================================================================================================
# Subroutine to return only the headers of the page in the form of a string. Not sure this is
# valuable. Somebody suggested it and in researching how to do it I did it. Thus it is here.
#====================================================================================================
sub get_headers($)
{
   my $lwp      = shift;
   my $headers = $lwp->as_string();
   my $i       = index($headers,"\n\n");
   if ($i > -1)
   {
      $headers = substr($headers,0,$i+1);
   }
   return $headers;
}
#===================================================================================
# Subroutine to load the configuration file into memory for manipulation
#===================================================================================

sub loadConfiguration($)
{
   #------------------------------------------
   # Parameters
   #------------------------------------------
   my $fileName = shift;

   #------------------------------------------
   # Working Variables
   #------------------------------------------
   my @pwConf;
   my $pageName      = '';
   my $pageAddress   = '';
   my $pageWatchType = '';
   my $pageNotify    = '';
   my $line          = '';
   my $option        = '';
   my $value         = '';

   #------------------------------------------
   # Program code
   #------------------------------------------

   open(PWC,glob($fileName)) or die "Unable to open page-watcher configuration file: $fileName: $!\n";
   @pwConf = <PWC>;
   close(PWC);

   foreach $line (@pwConf)
   {
      #--------------------------------------------------------------------------------
      # Blank Lines end all stanzas
      #--------------------------------------------------------------------------------
      if ($line =~ /^\s*$/)
      {
         $pageName      = '';
         $pageAddress   = '';
         $pageWatchType = '';
         $pageNotify    = '';
      }
      #--------------------------------------------------------------------------------
      # A Page definition
      #--------------------------------------------------------------------------------
      elsif ($line =~ /^(default)/i or $line =~ /^page\s*=\s*(\S+)/i)
      {
         $pageName=$1;
      }
      elsif ($pageName ne '' and $line =~ /^\s+(\S+)\s*=\s*(\S+)/)
      {
         $option = $1;
         $value  = $2;

         $option =~ tr/A-Z/a-z/;

         if ($option =~ /address/i)
         {
            $pageList{$pageName}=$value;
         }
         elsif ($option =~ /watchType/i)
         {
            $watchTypeList{$pageName}=$value;
         }
         elsif ($option =~ /notify/i)
         {
            $notifyList{$pageName} = $value;
         }
         else
         {
            die "Unrecognized option: $option specified for page: $pageName\n";
         }
      }
      #--------------------------------------------------------------------------------
      # Global main parms
      #   pageDB     = /home/tspdlp/code/perl/page-watch
      #   smtpServer = mail.tmcaz.com
      #   emailFrom  = PageWatcher@tmcaz.com
      #--------------------------------------------------------------------------------
      elsif ($line =~ /^pageDB\s*=\s*(\S+)/i)
      {
         $pageDB = $1;
      }
      elsif ($line =~ /^smtpServer\s*=\s*(\S+)/i)
      {
         $smtpServer = $1;
      }
      elsif ($line =~ /^emailFrom\s*=\s*(\S+)/i)
      {
         $emailFrom = $1;
      }
      elsif ($line =~ /^\s*#/i)
      {
         #do nothing... skip comments;
      }
      else
      {
         die "Unrecognized configuration option: $line\n";
      }
   }

   #--------------------------------------------------------------------------------
   # Verify that required information was supplied
   #--------------------------------------------------------------------------------
   if (!defined($pageDB))                   {die "Required parameter \"pageDB\" not found!\n";              }
   if (!defined($smtpServer))               {die "Required parameter \"smtpServer\" not found!\n";          }
   if (!defined($emailFrom))                {die "Required parameter \"emailFrom\" not found!\n";           }
   if (!defined($notifyList{'default'}))    {die "Required option of default \"notify\" not found!\n";      }
   if (!defined($watchTypeList{'default'})) {die "Required option of default \"watchType\" not found!\n";   }
   if (keys(%pageList) <= 0)                {die "No pages defined in configuration file";                  }
}
