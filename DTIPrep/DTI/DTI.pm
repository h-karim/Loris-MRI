=pod

=head1 NAME

DTI --- A set of utility functions for performing common tasks relating to DTI data (particularly with regards to perform DTI QC)

=head1 SYNOPSIS

use DTI;

my $dbh = DTI::connect_to_db();

=head1 DESCRIPTION

Really a mismatch of utility functions, primarily used by DTIPrep_pipeline.pl

=head1 METHODS

=cut

package DTI;

use Exporter();
use File::Basename;
use Getopt::Tabular;
use File::Path          'make_path';
use Date::Parse;
use MNI::Startup        qw(nocputimes);
use MNI::Spawn;
use MNI::FileUtilities  qw(check_output_dirs);

@ISA        = qw(Exporter);

@EXPORT     = qw();
@EXPORT_OK  = qw(createOutputFolders getFiles sortParam insertMincHeader create_FA_RGB_maps createNoteFile);

=pod
Create DTIPrep pipeline output folders.
=cut
sub createOutputFolders{
    my  ($outdir, $subjID, $visit, $protocol, $runDTIPrep) = @_;   
    
    my  $QC_out     =   $outdir . "/" .
                        $subjID . "/" .
                        $visit  . "/mri/processed/" .
                        substr(basename($protocol),0,-4);

    system("mkdir -p -m 755 $QC_out")   unless (-e $QC_out || !$runDTIPrep);


    return  ($QC_out) if (-e $QC_out);
}

=pod
Subroutine that will read the content of a directory and return a list of files matching the string given in argument with $match.
=cut
sub getFilesList {
    my ($dir, $match)   = @_;
    my (@files_list)    = ();

    ## Read directory $dir and stored its content in @entries 
    opendir  (DIR,"$dir")   ||  die "cannot open $dir\n";
    my @entries = readdir(DIR);
    closedir (DIR);

    ## Keep only files that match string stored in $match
    @files_list = grep(/$match/i, @entries);
    ## Add directory path to each element (file) of the array 
    @files_list = map  {"$dir/" . $_} @files_list;    

    return  (\@files_list);
}

=pod
Functionthat parses files in native MRI directory and grab the T1 acquisition based on $t1_scan_type.
If no anat was found, will return undef.
If multiple anat were found, will return the first anat of the list.
=cut
sub getAnatFile {
    my ($nativedir, $t1_scan_type)  = @_;

    # Fetch files in native directory that matched t1_scan_type
    my $anat_list   = DTI::getFilesList($nativedir, $t1_scan_type);

    # Return undef if no anat found, first anat otherwise
    if (@$anat_list == 0) { 
        return undef; 
    } else { 
        my $anat    = @$anat_list[0];
        return $anat;
    }
}

=pod
Function that parses files in native MRI directories and fetch DTI files. This function will also concatenate together multipleDTI files if DTI acquisition performed accross several DTI scans.
=cut
sub getRawDTIFiles{
    my ($nativedir, $DTI_volumes)   = @_;
    
    ## Get all mincs contained in native directory
    my ($mincs_list)    = DTI::getFilesList($nativedir, 'mnc$');

    ## Grab the mincs I want, a.k.a. with minc file with $DTI_volumes 
    my @DTI_frames  = split(',',$DTI_volumes);
    my @DTIs_list   = (); 
    foreach my $mnc (@$mincs_list) {
        if  (`mincinfo -dimnames $mnc` =~ m/time/)    {
            my $time    = `mincinfo -dimlength time $mnc`;
            chomp($time);
            if  ($time ~~ \@DTI_frames) {
                push (@DTIs_list, $mnc);
            }
        }
    }

    ## Return list of DTIs with the right volume numbers
    return  (\@DTIs_list);
}

=pod
Function that will copy the DTIPrep protocol used to the output directory of DTIPrep. 
=cut
sub copyDTIPrepProtocol {
    my ($DTIPrepProtocol, $QCProt)    =   @_;

    my $cmd = "cp $DTIPrepProtocol $QCProt";
    system($cmd)    unless (-e $QCProt);

    if (-e $QCProt) {
        return 1;
    } else {
        return undef;
    }
}

######################
sub Convert2mnc {

    # Convert QCed nrrd file back into minc file (with updated header)
    my  $insert_header;
    if  (-e $QCed_nrrd) {
        unless (-e $QCed_minc) {
            DTI::convert_DTI($QCed_nrrd, $QCed_minc, '--nrrd-to-minc');
            ($insert_header)    =   DTI::insertMincHeader($dti_file, 
                                                          $data_dir,
                                                          $QCed_minc, 
                                                          $QC_report, 
                                                          $DTIPrepVersion);
        }
    } 

    return  ($QCed_minc,$QC_report,$insert_header);
}

=pod
Function that will determine output names based on each DTI file dataset and return a hash of DTIref:
       dti_file_1  -> Raw_nrrd     => outputname
                   -> QCed_nrrd    => outputname
                   -> QCTxtReport  => outputname
                   -> QCXmlReport  => outputname
                   -> QCed_minc    => outputname
                   -> QCProt       => outputname
       dti_file_2  -> Raw_nrrd     => outputname etc...
=cut
sub createDTIhashref {
    my ($DTIs_list, $anat, $QCoutdir, $DTIPrepProtocol)    =   @_;
    my %DTIrefs;

    foreach my $dti_file (@$DTIs_list) {
        my $prot_name       = basename($DTIPrepProtocol);
        my $dti_name        = substr(basename($dti_file),0,-4);
        my $anat_name       = substr(basename($anat),0,-4);

        $DTIrefs{$dti_file}{'Raw_nrrd'}     = $QCoutdir . "/" . $dti_name  . ".nrrd"             ;
        $DTIrefs{$dti_file}{'QCed_nrrd'}    = $QCoutdir . "/" . $dti_name  . "_QCed.nrrd"        ;
        $DTIrefs{$dti_file}{'QCTxtReport'}  = $QCoutdir . "/" . $dti_name  . "_QCReport.txt"     ;
        $DTIrefs{$dti_file}{'QCXmlReport'}  = $QCoutdir . "/" . $dti_name  . "_XMLQCResult.xml"  ;
        $DTIrefs{$dti_file}{'QCed_minc'}    = $QCoutdir . "/" . $dti_name  . "_QCed.mnc"         ;
        $DTIrefs{$dti_file}{'QCProt'}       = $QCoutdir . "/" . $dti_name  . "_" . $prot_name    ;
        $DTIrefs{$dti_file}{'FA'}           = $QCoutdir . "/" . $dti_name  . "QCed_FA.mnc"       ;
        $DTIrefs{$dti_file}{'RGB'}          = $QCoutdir . "/" . $dti_name  . "QCed_rgb.mnc"      ;
        $DTIrefs{$dti_file}{'rgb_pic'}      = $QCoutdir . "/" . $dti_name  . "QCed_RGB.png"      ;   
        $DTIrefs{$dti_file}{'anat'}         = $anat                                              ;
        $DTIrefs{$dti_file}{'anat_mask'}    = $QCoutdir . "/" . $anat_name . "-n3-bet_mask.mnc"  ;
        $DTIrefs{$dti_file}{'preproc_minc'} = $QCoutdir . "/" . $anat_name . "-preprocessed.mnc" ;
    }
    
    return  (\%DTIrefs);
}

=pod
Function that convert minc file to nrrd or nrrd file to minc. 
(depending on $options)
=cut
sub convert_DTI {
    my  ($file_in, $file_out, $options)    =   @_;

    if  (!$options) { 
        print LOG "---DIED--- No options were define for conversion mnc2nrrd or nrrd2mnc.\n\n\n"; 
    }

    my  $cmd        =   "itk_convert $options --dwi $file_in $file_out";
    print "\n\tConverting $file_in to $file_out (...)\n$cmd\n";
    system($cmd)    unless (-e $file_out);

    if (-e $file_out) {
        return 1;   # successfully converted
    } else {
        return undef;   # failed during conversion
    }
}

=pod
Function that run DTIPrep on nrrd file
=cut
sub runDTIPrep {
    my  ($raw_nrrd, $protocol, $QCed_nrrd)  =   @_;    

    my  $cmd        =   "DTIPrep --DWINrrdFile $raw_nrrd --xmlProtocol $protocol";
    print   "\n\tRunning DTIPrep (...)\n$cmd\n";
    system($cmd)    unless (-e $QCed_nrrd);

    if (-e $QCed_nrrd) {
        return 1;
    } else {
        return undef;
    }
}

=pod

Insert in the minc header all the acquisition arguments except:
    - acquisition:bvalues
    - acquisition:direction_x
    - acquisition:direction_y
    - acquisition:direction_z
    - acquisition:b_matrix

Takes the raw DTI file and the QCed minc file as input and modify the QCed minc file based on the raw minc file's argument.

=cut
sub insertMincHeader {
    my  ($raw_dti, $data_dir, $processed_minc, $QC_report, $DTIPrepVersion)    =   @_;

    ### insert processing information in a mincheader field called processing:
    # 1) processing:sourceFile
    my  $sourceFile     =   $raw_dti;
    $sourceFile         =~  s/$data_dir//i;
    DTI::modify_header('processing:sourceFile', $sourceFile, $processed_minc);

    # 2) processing:sourceSeriesUID information (dicom_0x0020:el_0x000e field of $raw_dti)
    my  ($seriesUID)    =   DTI::fetch_header_info('dicom_0x0020:el_0x000e',$raw_dti,'$3, $4, $5, $6');
    DTI::modify_header('processing:sourceSeriesUID', $seriesUID, $processed_minc);

    # 3) processing:pipeline used
    DTI::modify_header('processing:pipeline', $DTIPrepVersion, $processed_minc);


#    # 1) EchoTime in the minc file
#    my  ($SourceEchoTime)   =   DTI::fetch_header_info('acquisition:echo_time',$raw_dti,'$3, $4, $5, $6');
#    DTI::modify_header('processing:sourceEchoTime', $SourceEchoTime, $QCed_minc);

    # 4) processing:processing_date (when DTIPrep was run)
    my  $check_line     =   `cat $QC_report | grep "Check Time"`;
    $check_line         =~  s/Check Time://;      # Only keep date info in $check_line.
    my ($ss,$mm,$hh,$day,$month,$year,$zone)    =   strptime($check_line);
    my $processingDate  =  sprintf("%4d%02d%02d",$year+1900,$month+1,$day);
    DTI::modify_header('processing:processing_date', $processingDate, $processed_minc);

    ### reinsert old acquisition, patient and study arguments except for the one modified by DTIPrep (i.e. acquisition:bvalues, acquisition:b_matrix and all acquisition:direction*)
    # 1) acquisition:b_value insertion
    my  ($b_value)  =   DTI::fetch_header_info('acquisition:b_value',$raw_dti,'$3, $4, $5, $6');
    DTI::modify_header('acquisition:b_value', $b_value, $processed_minc);

    # 2) acquisition:delay_in_TR insertion
    my  ($delay_in_tr)  =   DTI::fetch_header_info('acquisition:delay_in_TR',$raw_dti,'$3, $4, $5, $6');
    DTI::modify_header('acquisition:delay_in_TR', $delay_in_TR, $processed_minc);

    # 3) all the remaining acquisition:* arguments 
    #    [except acquisition:bvalues, acquisition:b_matrix and acquisition:direction* (already in header from nrrd2minc conversion)]
    my  ($acquisition_args) =   DTI::fetch_header_info('acquisition:[^dbv]',$raw_dti,'$1, $2');
    my  ($patient_args)     =   DTI::fetch_header_info('patient:',$raw_dti,'$1, $2');
    my  ($study_args)       =   DTI::fetch_header_info('study:',$raw_dti,'$1, $2');

    # fetches header info and don't remove semi_colon (last option of fetch_header_info).
    my  ($acquisition_vals) =   DTI::fetch_header_info('acquisition:[^dbv]',$raw_dti,'$3, $4, $5, $6',1);
    my  ($patient_vals)     =   DTI::fetch_header_info('patient:',$raw_dti,'$3, $4, $5, $6',1);
    my  ($study_vals)       =   DTI::fetch_header_info('study:',$raw_dti,'$3, $4, $5, $6',1);

    my  ($arguments,$values);
    if  ($processed_minc=~/(_FA\.mnc|_rgb\.mnc)$/i) {
        $arguments  =   $patient_args . $study_args;
        $values     =   $patient_vals . $study_vals;
    } elsif ($processed_minc=~/_QCed\.mnc/i) {
        $arguments  =   $acquisition_args . $patient_args . $study_args;
        $values     =   $acquisition_vals . $patient_vals . $study_vals;
    }
    my  ($arguments_list, $arguments_list_size) =   get_header_list('=', $arguments);
    my  ($values_list, $values_list_size)       =   get_header_list(';', $values);

    if  ($arguments_list_size   ==  $values_list_size)  {
        for (my $i=0;   $i<$arguments_list_size;    $i++)   {
            my  $argument   =   @$arguments_list[$i];
            my  $value      =   @$values_list[$i];
            DTI::modify_header($argument, $value, $processed_minc);
        }
        return  1;
    }else {
        return  undef;
    }
}

=pod
Function that runs minc_modify_header.
=cut
sub modify_header {
    my  ($argument, $value, $minc) =   @_;
    
    my  $cmd    =   "minc_modify_header -sinsert $argument=$value $minc";
    system($cmd);
}

=pod

=cut
sub fetch_header_info {
    my  ($field, $minc, $awk, $keep_semicolon)  =   @_;

    my  $val    =   `mincheader $minc | grep $field | awk '{print $awk}' | tr '\n' ' '`;
    my  $value  =   $val    if  $val !~ /^\s*"*\s*"*\s*$/;
    $value      =~  s/^\s+//;                           # remove leading spaces
    $value      =~  s/\s+$//;                           # remove trailing spaces
    $value      =~  s/;//   unless ($keep_semicolon);   # remove ";" unless $keep_semicolon is defined

    return  ($value);
}

=pod
Get the list of arguments and values to insert into the mincheader (acquisition:*, patient:* and study:*).
=cut
sub get_header_list {
    my  ($splitter, $fields) =   @_;
    
    my  @tmp    =   split   ($splitter, $fields);
    pop (@tmp);
    my  @items;
    foreach my $item (@tmp) { 
        $item   =~  s/^\s+//;   # remove leading spaces
        $item   =~  s/\s+$//;   # remove trailing spaces
        push    (@items, $item);
    }
    my  $list       =   \@items;
    my  $list_size  =   @$list;
    
    return  ($list, $list_size);
}

=pod
Function that created FA and RGB maps as well as the triplanar pic of the RGB map. 
=cut
sub create_FA_RGB_maps {
    my ($dti_file, $DTIrefs, $QCoutdir)   =   @_;

    # Initialize variables
    my $QCed_minc     = $DTIrefs->{$dti_file}{'QCed_minc'}    ;
    my $QCed_basename = substr(basename($QCed_minc),0,-4)     ;
    my $FA            = $DTIrefs->{$dti_file}{'FA'}           ;
    my $RGB           = $DTIrefs->{$dti_file}{'RGB'}          ;
    my $rgb_pic       = $DTIrefs->{$dti_file}{'rgb_pic'}      ;
    my $preproc_minc  = $DTIrefs->{$dti_file}{'preproc_minc'} ;
    my $anat_mask     = $DTIrefs->{$dti_file}{'anat_mask'}    ;
    my $anat          = $DTIrefs->{$dti_file}{'anat'}         ;

    # Check if output files already exists
    if (-e $rgb_pic && $RGB && $anat_mask && $preproc_minc) {
        return  0;
    }

    # Run diff_preprocess.pl pipeline if anat and QCed dti exists. Return 1 otherwise
    if (-e $anat && $QCed_minc) {
        `diff_preprocess.pl -anat $anat $QCed_minc $preproc_minc -outdir $QCoutdir`   unless (-e $preproc_minc);
    } else {
        return  1;
    } 

    # Run minctensor.pl if anat mask and preprocessed minc exist
    if (-e $anat_mask && $preproc_minc) {
        `minctensor.pl -mask $anat_mask $preproc_minc -niakdir /opt/niak-0.6.4.1/ -outputdir $QCoutdir -octave $QCed_basename`  unless (-e $FA);
    } else {
        return  2;
    }

    # Run mincpik if RGB map exists. Should remove this since it will be created once pipeline finalized
    if (-e $RGB) {
        `mincpik -triplanar -horizontal $RGB $rgb_pic`  unless (-e $rgb_pic);
    } else {
        return  3;
    }
    
    # Return yes if everything was successful
    $success    = "yes";
    return  ($success);
}

=pod
Create a default notes file for QC summary and manual notes.
=cut
sub createNoteFile {
    my ($QC_out, $note_file, $QC_report, $reject_thresh)    =   @_;

    my ($rm_slicewise, $rm_interlace, $rm_intergradient)    =   getRejectedDirections($QC_report);

    my $count_slice     =   insertNote($note_file, $rm_slicewise,      "slicewise correlations");
    my $count_inter     =   insertNote($note_file, $rm_interlace,      "interlace correlations");
    my $count_gradient  =   insertNote($note_file, $rm_intergradient,  "gradient-wise correlations");

    my $total           =   $count_slice + $count_inter + $count_gradient;
    open    (NOTES, ">>$note_file");
    print   NOTES   "Total number of directions rejected by auto QC= $total\n";
    close   (NOTES);
    if  ($total >=  $reject_thresh) {   
        print NOTES "FAIL\n";
    } else {
        print NOTES "PASS\n";
    }

}

=pod
Get the list of directions rejected by DTI per type (i.e. slice-wise correlations, inter-lace artifacts, inter-gradient artifacts).
=cut
sub getRejectedDirections   {
    my ($QCReport)  =   @_;

    ## these are the unique directions that were rejected due to slice-wise correlations
    my $rm_slicewise    =   `cat $QCReport | grep whole | sort -k 2,2 -u | awk '{print \$2}'|tr '\n' ','`;
    ## these are the unique directions that were rejected due to inter-lace artifacts
    my $rm_interlace    =   `cat $QCReport | sed -n -e '/Interlace-wise Check Artifacts/,/================================/p' | grep '[0-9]' | sort -k 1,1 -u | awk '{print \$1}'|tr '\n' ','`;
    ## these are the unique directions that were rejected due to inter-gradient artifacts
    my $rm_intergradient=   `cat $QCReport | sed -n -e '/Inter-gradient check Artifacts::/,/================================/p' | grep '[0-9]'| sort -k 1,1 -u  | awk '{print \$1}'|tr '\n' ','`;
    
    return ($rm_slicewise, $rm_interlace, $rm_intergradient);
}

=sub
Insert into notes file the directions rejected due to a specific artifact.
=cut
sub insertNote    {
    my ($note_file, $rm_directions, $note_field)    =   @_;

    my @rm_dirs     =   split(',',$rm_directions);
    my $count_dirs  =   scalar(@rm_dirs);

    open    (NOTES, ">>$note_file");
    print   NOTES   "Directions rejected due to $note_field: @rm_dirs ($count_dirs)\n";
    close   (NOTES);

    return  ($count_dirs);
}
