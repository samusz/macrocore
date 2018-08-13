/**
  @file
  @brief Create a type 1 Stored Process (9.2 compatible)
  @details This macro creates a Type 1 stored process, and also the necessary
    PromptGroup / File / TextStore objects.  It requires the location (or uri)
    for the App Server / Directory / Folder (Tree) objects.
    To upgrade this macro to work with type 2 (which can embed SAS code
    and is compabitible with SAS from 9.3 onwards) then the UsageVersion should
    change to 2000000 and the TextStore object updated.  The ComputeServer
    reference will also be to ServerContext rather than LogicalServer.

    This macro is idempotent - if you run it twice, it will only create an STP
    once.

  usage (type 1 STP):

      %mm_createstp(stpname=MyNewSTP
        ,filename=mySpecialProgram.sas
        ,directory=SASEnvironment/SASCode/STPs
        ,tree=/User Folders/sasdemo
        ,outds=work.uris)

  If you wish to remove the new STP you can do so by running:

      data _null_;
        set work.uris;
        rc1 = METADATA_DELOBJ(texturi);
        rc2 = METADATA_DELOBJ(prompturi);
        rc3 = METADATA_DELOBJ(fileuri);
        rc4 = METADATA_DELOBJ(stpuri);
        putlog (_all_)(=);
      run;

  usage (type 2 STP):
      %mm_createstp(stpname=MyNewType2STP
        ,filename=mySpecialProgram.sas
        ,directory=SASEnvironment/SASCode/STPs
        ,tree=/User Folders/sasdemo
        ,Server=SASApp
        ,stptype=2)

  @param stpname= Stored Process name.  Avoid spaces - testing has shown that
    the check to avoid creating multiple STPs in the same folder with the same
    name does not work when the name contains spaces.
  @param stpdesc= Stored Process description (optional)
  @param filename= the name of the .sas program to run
  @param directory= The directory uri, or the actual path to the sas program
    (no trailing slash).  If more than uri is found with that path, then the
    first one will be used.
  @param tree= The metadata folder uri, or the metadata path, in which to
    create the STP.
  @param server= The server which will run the STP.  Server name or uri is fine.
  @param outds= The two level name of the output dataset.  Will contain all the
    meta uris. Defaults to work.mm_createstp.
  @param mDebug= set to 1 to show debug messages in the log
  @param stptype= Default is 1 (STP code saved on filesystem).  Set to 2 if
    source code is to be saved in metadata (9.3 and above feature).
  @param frefin= fileref to use (enables change if there is a conflict).  The
    filerefs are left open, to enable inspection after running the
    macro (or importing into an xmlmap if needed).
  @param frefout= fileref to use (enables change if there is a conflict)

  @returns outds  dataset containing the following columns:
   - stpuri
   - prompturi
   - fileuri
   - texturi

  @version 9.2
  @author Allan Bowe
  @copyright GNU GENERAL PUBLIC LICENSE v3

**/

%macro mm_createstp(
     stpname=Macro People STP
    ,stpdesc=This stp was created automatically by the mm_createstp macro
    ,filename=mm_createstp.sas
    ,directory=SASEnvironment/SASCode
    ,tree=/User Folders/sasdemo
    ,package=false
    ,streaming=true
    ,outds=work.mm_createstp
    ,mDebug=0
    ,server=SASApp - Logical Stored Process Server
    ,stptype=1
    ,frefin=mm_in
    ,frefout=mm_out
)/*/STORE SOURCE*/;

%local mD;
%if &mDebug=1 %then %let mD=;
%else %let mD=%str(*);
%&mD.put Executing mm_CreateSTP.sas;
%&mD.put _local_;

%mf_verifymacvars(stpname filename directory tree)
%mp_dropmembers(%scan(&outds,2,.))

/**
 * check tree exists
 */
data _null_;
  length type uri $256;
  rc=metadata_pathobj("","&tree","Folder",type,uri);
  call symputx('foldertype',type,'l');
  call symputx('treeuri',uri,'l');
run;
%if &foldertype ne Tree %then %do;
  %put WARNING: Tree &tree does not exist!;
  %return;
%end;

/**
 * Check STP does not exist already
 */
data _null_;
  length type uri $256;
  rc=metadata_pathobj("","&tree/&stpname",'StoredProcess',type,uri);
  call symputx('cmtype',type,'l');
  call symputx('stpuri',uri,'l');
run;
%if &cmtype = ClassifierMap %then %do;
  %put WARNING: Stored Process &stpname already exists in &tree!;
  %return;
%end;

/**
 * Check that the physical file exists
 */
%if %sysfunc(fileexist(&directory/&filename)) ne 1 %then %do;
  %put WARNING: FILE *&directory/&filename* NOT FOUND!;
  %return;
%end;

%if stptype=1 %then %do;
  /* type 1 STP - where code is stored on filesystem */
  %if %sysevalf(&sysver lt 9.2) %then %do;
    %put WARNING: Version 9.2 or later required;
    %return;
  %end;

  /* check directory object (where 9.2 source code reference is stored) */
  data _null_;
    length id $20 dirtype $256;
    rc=metadata_resolve("&directory",dirtype,id);
    call symputx('checkdirtype',dirtype,'l');
  run;

  %if &checkdirtype ne Directory %then %do;
    %mm_getDirectories(path=&directory,outds=&outds ,mDebug=&mDebug)
    %if %mf_nobs(&outds)=0 or %sysfunc(exist(&outds))=0 %then %do;
      %put WARNING: The directory object does not exist for &directory;
      %return;
    %end;
  %end;
  %else %do;
    data &outds;
      directoryuri="&directory";
    run;
  %end;

  data &outds (keep=stpuri prompturi fileuri texturi);
    length stpuri prompturi fileuri texturi serveruri $256 ;
    set &outds;

    /* final checks on uris */
    length id $20 type $256;
    __rc=metadata_resolve("&treeuri",type,id);
    if type ne 'Tree' then do;
      putlog "WARNING:  Invalid tree URI: &treeuri";
      stopme=1;
    end;
    __rc=metadata_resolve(directoryuri,type,id);
    if type ne 'Directory' then do;
      putlog 'WARNING:  Invalid directory URI: ' directoryuri;
      stopme=1;
    end;

  /* get server info */
    __rc=metadata_resolve("&server",type,serveruri);
    if type ne 'LogicalServer' then do;
      __rc=metadata_getnobj("omsobj:LogicalServer?@Name='&server'",1,serveruri);
      if serveruri='' then do;
        putlog "WARNING:  Invalid server: &server";
        stopme=1;
      end;
    end;

    if stopme=1 then do;
      putlog (_all_)(=);
      stop;
    end;

    /* create empty prompt */
    rc1=METADATA_NEWOBJ('PromptGroup',prompturi,'Parameters');
    rc2=METADATA_SETATTR(prompturi, 'UsageVersion', '1000000');
    rc3=METADATA_SETATTR(prompturi, 'GroupType','2');
    rc4=METADATA_SETATTR(prompturi, 'Name','Parameters');
    rc5=METADATA_SETATTR(prompturi, 'PublicType','Embedded:PromptGroup');
    GroupInfo="<PromptGroup promptId='PromptGroup_%sysfunc(datetime())_&sysprocessid'"
      !!" version='1.0'><Label><Text xml:lang='en-GB'>Parameters</Text>"
      !!"</Label></PromptGroup>";
    rc6 = METADATA_SETATTR(prompturi, 'GroupInfo',groupinfo);

    if sum(of rc1-rc6) ne 0 then do;
      putlog 'WARNING: Issue creating prompt.';
      if prompturi ne . then do;
        putlog '  Removing orphan: ' prompturi;
        rc = METADATA_DELOBJ(prompturi);
        put rc=;
      end;
      stop;
    end;

    /* create a file uri */
    rc7=METADATA_NEWOBJ('File',fileuri,'SP Source File');
    rc8=METADATA_SETATTR(fileuri, 'FileName',"&filename");
    rc9=METADATA_SETATTR(fileuri, 'IsARelativeName','1');
    rc10=METADATA_SETASSN(fileuri, 'Directories','MODIFY',directoryuri);
    if sum(of rc7-rc10) ne 0 then do;
      putlog 'WARNING: Issue creating file.';
      if fileuri ne . then do;
        putlog '  Removing orphans:' prompturi fileuri;
        rc = METADATA_DELOBJ(prompturi);
        rc = METADATA_DELOBJ(fileuri);
        put (_all_)(=);
      end;
      stop;
    end;

    /* create a TextStore object */
    rc11= METADATA_NEWOBJ('TextStore',texturi,'Stored Process');
    rc12= METADATA_SETATTR(texturi, 'TextRole','StoredProcessConfiguration');
    rc13= METADATA_SETATTR(texturi, 'TextType','XML');
    storedtext='<?xml version="1.0" encoding="UTF-8"?><StoredProcess>'
      !!"<ResultCapabilities Package='&package' Streaming='&streaming'/>"
      !!"<OutputParameters/></StoredProcess>";
    rc14= METADATA_SETATTR(texturi, 'StoredText',storedtext);
    if sum(of rc11-rc14) ne 0 then do;
      putlog 'WARNING: Issue creating TextStore.';
      if texturi ne . then do;
        putlog '  Removing orphans: ' prompturi fileuri texturi;
        rc = METADATA_DELOBJ(prompturi);
        rc = METADATA_DELOBJ(fileuri);
        rc = METADATA_DELOBJ(texturi);
        put (_all_)(=);
      end;
      stop;
    end;

    /* create meta obj */
    rc15= METADATA_NEWOBJ('ClassifierMap',stpuri,"&stpname");
    rc16= METADATA_SETASSN(stpuri, 'Trees','MODIFY',treeuri);
    rc17= METADATA_SETASSN(stpuri, 'ComputeLocations','MODIFY',serveruri);
    rc18= METADATA_SETASSN(stpuri, 'SourceCode','MODIFY',fileuri);
    rc19= METADATA_SETASSN(stpuri, 'Prompts','MODIFY',prompturi);
    rc20= METADATA_SETASSN(stpuri, 'Notes','MODIFY',texturi);
    rc21= METADATA_SETATTR(stpuri, 'PublicType', 'StoredProcess');
    rc22= METADATA_SETATTR(stpuri, 'TransformRole', 'StoredProcess');
    rc23= METADATA_SETATTR(stpuri, 'UsageVersion', '1000000');
    rc24= METADATA_SETATTR(stpuri, 'Desc', "&stpdesc");

    /* tidy up if error */
    if sum(of rc15-rc24) ne 0 then do;
      putlog 'WARNING: Issue creating STP.';
      if stpuri ne . then do;
        putlog '  Removing orphans: ' prompturi fileuri texturi stpuri;
        rc = METADATA_DELOBJ(prompturi);
        rc = METADATA_DELOBJ(fileuri);
        rc = METADATA_DELOBJ(texturi);
        rc = METADATA_DELOBJ(stpuri);
        put (_all_)(=);
      end;
    end;
    else do;
      fullpath=cats('_program=',treepath,"/&stpname");
      putlog "NOTE: Stored Process Created!";
      putlog "NOTE- "; putlog "NOTE-"; putlog "NOTE-" fullpath;
      putlog "NOTE- "; putlog "NOTE-";
    end;
    output;
    stop;
  run;
%end;
%else %if &stptype=2 %then %do;
  /* type 2 stp - code is stored in metadata */
  %if %sysevalf(&sysver lt 9.3) %then %do;
    %put WARNING: SAS version 9.3 or later required to create type2 STPs;
    %return;
  %end;
  /* check we have the correct ServerContext */
  data _null_;
    length type uri $256;
    rc=metadata_resolve("omsobj:ServerContext?@Name='&server'",type,uri);
    call symputx('servertype',type,'l');
    call symputx('serveruri',uri,'l');
  run;
  %if &servertype ne ServerContext %then %do;
    %put WARNING: ServerContext *&server* not found!;
    %return;
  %end;

  /**
   * First, create a Hello World type 2 stored process
   */
  filename &frefin temp;
  data _null_;
    file &frefin;
    treeuri=quote(symget('treeuri'));
    serveruri=quote(symget('serveruri'));
    stpdesc=quote(symget('stpdesc'));
    stpname=quote(symget('stpname'));

    put "<AddMetadata><Reposid>$METAREPOSITORY</Reposid><Metadata> "/
    '<ClassifierMap UsageVersion="2000000" IsHidden="0" IsUserDefined="0" '/
    ' IsActive="1" PublicType="StoredProcess" TransformRole="StoredProcess" '/
    '  Name=' stpname ' Desc=' stpdesc '>'/
    "  <ComputeLocations>"/
    "    <ServerContext ObjRef=" serveruri "/>"/
    "  </ComputeLocations>"/
    "<Notes> "/
    '  <TextStore IsHidden="0"  Name="SourceCode" UsageVersion="0" '/
    '    TextRole="StoredProcessSourceCode" StoredText="%put hello world!;" />'/
    '  <TextStore IsHidden="0" Name="Stored Process" UsageVersion="0" '/
    '    TextRole="StoredProcessConfiguration" TextType="XML" '/
    '    StoredText="&lt;?xml version=&quot;1.0&quot; encoding=&quot;UTF-8&qu'@@
    'ot;?&gt;&lt;StoredProcess&gt;&lt;ServerContext LogicalServerType=&quot;S'@@
    'ps&quot; OtherAllowed=&quot;false&quot;/&gt;&lt;ResultCapabilities Packa'@@
    'ge=&quot;' @@ "&package" @@ '&quot; Streaming=&quot;' @@ "&streaming" @@
    '&quot;/&gt;&lt;OutputParameters/&gt;&lt;/StoredProcess&gt;" />' /
    "  </Notes> "/
    "  <Prompts> "/
    '   <PromptGroup  Name="Parameters" GroupType="2" IsHidden="0" '/
    '     PublicType="Embedded:PromptGroup" UsageVersion="1000000" '/
    '     GroupInfo="&lt;PromptGroup promptId=&quot;PromptGroup_1502797359253'@@
    '_802080&quot; version=&quot;1.0&quot;&gt;&lt;Label&gt;&lt;Text xml:lang='@@
    '&quot;en-US&quot;&gt;Parameters&lt;/Text&gt;&lt;/Label&gt;&lt;/PromptGro'@@
    'up&gt;" />'/
    "  </Prompts> "/
    "<Trees><Tree ObjRef=" treeuri "/></Trees>"/
    "</ClassifierMap></Metadata><NS>SAS</NS>"/
    "<Flags>268435456</Flags></AddMetadata>";
  run;

  filename &frefout temp;

  proc metadata in= &frefin out=&frefout verbose;
  run;

  %if &mdebug=1 %then %do;
    /* write the response to the log for debugging */
    data _null_;
      infile &frefout lrecl=1048576;
      input;
      put _infile_;
    run;
  %end;

  /**
   * Next, add the source code
   */
  %mm_updatestpsourcecode(stp=&tree/&stpname
    ,stpcode="&directory/&filename"
    ,frefin=&frefin.
    ,frefout=&frefout.
    ,mdebug=&mdebug)

/*
<GetMetadata>
  <Reposid>A0000001.A5RIITO4</Reposid>
  <Metadata>
    <ClassifierMap id="A5RIITO4.BC0000NW" Desc="undefined" IsActive="1" IsHidden="0" IsUserDefined="0" Name="buildUserNavigator" PublicType="StoredProcess" TransformRole="StoredProcess" UsageVersion="2000000">
      <ComputeLocations>
        <ServerContext Id="A5RIITO4.AT000002" Name="SASApp"/>
      </ComputeLocations>
      <Notes>
        <TextStore Id="A5RIITO4.AG0001YW" Name="SourceCode"/>
        <TextStore Id="A5RIITO4.AG0001YX" Name="Stored Process"/>
      </Notes>
      <Prompts>
        <PromptGroup Id="A5RIITO4.B80000I6" Name="Parameters"/>
      </Prompts>
     <Trees><Tree id="blah" name="blah"></Trees>
    </ClassifierMap>
  </Metadata>
  <NS>SAS</NS>
  <Flags>2049</Flags>
</GetMetadata>
*/

%end;
%else %do;
  %put WARNING:  STPTYPE=*&stptype* not recognised!;
%end;
%mend;