/*

SQL Server Backup, Integrity Check and Index Optimization.

The solution is supported on SQL Server 2005 and SQL Server 2008.

The documentation is available on http://ola.hallengren.com/Documentation.html.
My e-mail address is ola@hallengren.com. Please feel free to contact me.

Ola Hallengren
http://ola.hallengren.com

*/

USE dbamaint -- <== This is the database that the objects will be created in.

SET NOCOUNT ON

DECLARE @BackupDirectory nvarchar(max)
DECLARE @CreateJobs nvarchar(max)
DECLARE @Error int

SET @BackupDirectory = N'C:\Backup' -- <== Change this to your backup directory.

SET @CreateJobs = 'Y' -- <== Should jobs be created, 'Y' or 'N'?

SET @Error = 0

IF IS_SRVROLEMEMBER('sysadmin') = 0
BEGIN
  RAISERROR('The server role SysAdmin is needed for the installation.',16,1)
  SET @Error = @@ERROR
END

IF CAST(LEFT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max)),CHARINDEX('.',CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max)))-1) + '.' + REPLACE(RIGHT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max)), LEN(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max))) - CHARINDEX('.',CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max)))),'.','') AS numeric(18,9)) < 9
BEGIN
  RAISERROR('The solution is supported on SQL Server 2005 and SQL Server 2008.',16,1)
  SET @Error = @@ERROR
END

IF (SELECT [compatibility_level] FROM sys.databases WHERE database_id = DB_ID()) < 90
BEGIN
  RAISERROR('The database that you are creating the objects in has to be in compatibility_level 90 or 100.',16,1)
  SET @Error = @@ERROR
END

IF (SELECT value_in_use FROM sys.configurations WHERE name = 'Agent XPs') <> 1 AND SERVERPROPERTY('EngineEdition') <> 4 AND @CreateJobs = 'Y'
BEGIN
  RAISERROR('The SQL Server Agent has to be started.',16,1)
  SET @Error = @@ERROR
END

IF OBJECT_ID('tempdb..#Config') IS NOT NULL DROP TABLE #Config

CREATE TABLE #Config ([Name] nvarchar(max),
                      [Value] nvarchar(max))

DECLARE @ErrorLog TABLE (LogDate datetime,
                         ProcessInfo nvarchar(max),
                         ErrorText nvarchar(max))

INSERT INTO @ErrorLog (LogDate, ProcessInfo, ErrorText)
EXECUTE [master].dbo.sp_readerrorlog 0

IF @@ERROR <> 0
BEGIN
  RAISERROR('Error reading from the error log.',16,1)
  SET @Error = @@ERROR
END

INSERT INTO #Config ([Name], [Value])
SELECT 'LogDirectory', REPLACE(REPLACE(ErrorText,'Logging SQL Server messages in file ''',''),'\ERRORLOG''.','')
FROM @ErrorLog
WHERE ErrorText LIKE 'Logging SQL Server messages in file%'

IF @@ERROR <> 0 OR @@ROWCOUNT <> 1
BEGIN
  RAISERROR('The log directory could not be found.',16,1)
  SET @Error = @@ERROR
END

INSERT INTO #Config ([Name], [Value])
VALUES('BackupDirectory', @BackupDirectory)

INSERT INTO #Config ([Name], [Value])
VALUES('Database', DB_NAME(DB_ID()))

INSERT INTO #Config ([Name], [Value])
VALUES('Jobs', @CreateJobs)

INSERT INTO #Config ([Name], [Value])
VALUES('Error', CAST(@Error AS nvarchar))

IF OBJECT_ID('dbo.DatabaseBackup') IS NOT NULL DROP PROCEDURE dbo.DatabaseBackup
IF OBJECT_ID('dbo.DatabaseIntegrityCheck') IS NOT NULL DROP PROCEDURE dbo.DatabaseIntegrityCheck
IF OBJECT_ID('dbo.IndexOptimize') IS NOT NULL DROP PROCEDURE dbo.IndexOptimize
IF OBJECT_ID('dbo.CommandExecute') IS NOT NULL DROP PROCEDURE dbo.CommandExecute
IF OBJECT_ID('dbo.DatabaseSelect') IS NOT NULL DROP FUNCTION dbo.DatabaseSelect
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE FUNCTION [dbo].[DatabaseSelect] (@DatabaseList nvarchar(max))

RETURNS @Database TABLE (DatabaseName nvarchar(max) NOT NULL)

AS

BEGIN

  ----------------------------------------------------------------------------------------------------
  --// Declare variables                                                                          //--
  ----------------------------------------------------------------------------------------------------

  DECLARE @DatabaseItem nvarchar(max)
  DECLARE @Position int

  DECLARE @CurrentID int
  DECLARE @CurrentDatabaseName nvarchar(max)
  DECLARE @CurrentDatabaseStatus bit

  DECLARE @Database01 TABLE (DatabaseName nvarchar(max))

  DECLARE @Database02 TABLE (ID int IDENTITY PRIMARY KEY,
                             DatabaseName nvarchar(max),
                             DatabaseStatus bit,
                             Completed bit)

  DECLARE @Database03 TABLE (DatabaseName nvarchar(max),
                             DatabaseStatus bit)

  DECLARE @Sysdatabases TABLE (DatabaseName nvarchar(max))

  ----------------------------------------------------------------------------------------------------
  --// Split input string into elements                                                           //--
  ----------------------------------------------------------------------------------------------------

  SET @DatabaseList = REPLACE(REPLACE(REPLACE(REPLACE(@DatabaseList,'[',''),']',''),'''',''),'"','')

  WHILE CHARINDEX(',,',@DatabaseList) > 0 SET @DatabaseList = REPLACE(@DatabaseList,',,',',')
  WHILE CHARINDEX(', ',@DatabaseList) > 0 SET @DatabaseList = REPLACE(@DatabaseList,', ',',')
  WHILE CHARINDEX(' ,',@DatabaseList) > 0 SET @DatabaseList = REPLACE(@DatabaseList,' ,',',')

  IF RIGHT(@DatabaseList,1) = ',' SET @DatabaseList = LEFT(@DatabaseList,LEN(@DatabaseList) - 1)
  IF LEFT(@DatabaseList,1) = ','  SET @DatabaseList = RIGHT(@DatabaseList,LEN(@DatabaseList) - 1)

  SET @DatabaseList = LTRIM(RTRIM(@DatabaseList))

  WHILE LEN(@DatabaseList) > 0
  BEGIN
    SET @Position = CHARINDEX(',', @DatabaseList)
    IF @Position = 0
    BEGIN
      SET @DatabaseItem = @DatabaseList
      SET @DatabaseList = ''
    END
    ELSE
    BEGIN
      SET @DatabaseItem = LEFT(@DatabaseList, @Position - 1)
      SET @DatabaseList = RIGHT(@DatabaseList, LEN(@DatabaseList) - @Position)
    END
    IF @DatabaseItem <> '-' INSERT INTO @Database01 (DatabaseName) VALUES(@DatabaseItem)
  END

  ----------------------------------------------------------------------------------------------------
  --// Handle database exclusions                                                                 //--
  ----------------------------------------------------------------------------------------------------

  INSERT INTO @Database02 (DatabaseName, DatabaseStatus, Completed)
  SELECT DISTINCT DatabaseName = CASE WHEN DatabaseName LIKE '-%' THEN RIGHT(DatabaseName,LEN(DatabaseName) - 1) ELSE DatabaseName END,
                  DatabaseStatus = CASE WHEN DatabaseName LIKE '-%' THEN 0 ELSE 1 END,
                  0 AS Completed
  FROM @Database01

  ----------------------------------------------------------------------------------------------------
  --// Resolve elements                                                                           //--
  ----------------------------------------------------------------------------------------------------

  WHILE EXISTS (SELECT * FROM @Database02 WHERE Completed = 0)
  BEGIN

    SELECT TOP 1 @CurrentID = ID,
                 @CurrentDatabaseName = DatabaseName,
                 @CurrentDatabaseStatus = DatabaseStatus
    FROM @Database02
    WHERE Completed = 0
    ORDER BY ID ASC

    IF @CurrentDatabaseName = 'SYSTEM_DATABASES'
    BEGIN
      INSERT INTO @Database03 (DatabaseName, DatabaseStatus)
      SELECT [name], @CurrentDatabaseStatus
      FROM sys.databases
      WHERE database_id <= 4
    END
    ELSE IF @CurrentDatabaseName = 'USER_DATABASES'
    BEGIN
      INSERT INTO @Database03 (DatabaseName, DatabaseStatus)
      SELECT [name], @CurrentDatabaseStatus
      FROM sys.databases
      WHERE database_id > 4
    END
    ELSE IF CHARINDEX('%',@CurrentDatabaseName) > 0
    BEGIN
      INSERT INTO @Database03 (DatabaseName, DatabaseStatus)
      SELECT [name], @CurrentDatabaseStatus
      FROM sys.databases
      WHERE [name] LIKE REPLACE(@CurrentDatabaseName,'_','[_]')
    END
    ELSE
    BEGIN
      INSERT INTO @Database03 (DatabaseName, DatabaseStatus)
      SELECT [name], @CurrentDatabaseStatus
      FROM sys.databases
      WHERE [name] = @CurrentDatabaseName
    END

    UPDATE @Database02
    SET Completed = 1
    WHERE ID = @CurrentID

    SET @CurrentID = NULL
    SET @CurrentDatabaseName = NULL
    SET @CurrentDatabaseStatus = NULL

  END

  ----------------------------------------------------------------------------------------------------
  --// Handle tempdb and database snapshots                                                       //--
  ----------------------------------------------------------------------------------------------------

  INSERT INTO @Sysdatabases (DatabaseName)
  SELECT [name]
  FROM sys.databases
  WHERE [name] <> 'tempdb'
  AND source_database_id IS NULL

  ----------------------------------------------------------------------------------------------------
  --// Return results                                                                             //--
  ----------------------------------------------------------------------------------------------------

  INSERT INTO @Database (DatabaseName)
  SELECT DatabaseName
  FROM @Sysdatabases
  INTERSECT
  SELECT DatabaseName
  FROM @Database03
  WHERE DatabaseStatus = 1
  EXCEPT
  SELECT DatabaseName
  FROM @Database03
  WHERE DatabaseStatus = 0

  RETURN

  ----------------------------------------------------------------------------------------------------

END
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[CommandExecute]

@Command nvarchar(max),
@Comment nvarchar(max),
@Mode int,
@Execute nvarchar(max)

AS

BEGIN

  ----------------------------------------------------------------------------------------------------
  --// Set options                                                                                //--
  ----------------------------------------------------------------------------------------------------

  SET NOCOUNT ON

  SET LOCK_TIMEOUT 3600000

  ----------------------------------------------------------------------------------------------------
  --// Declare variables                                                                          //--
  ----------------------------------------------------------------------------------------------------

  DECLARE @StartMessage nvarchar(max)
  DECLARE @EndMessage nvarchar(max)
  DECLARE @ErrorMessage nvarchar(max)

  DECLARE @StartTime datetime
  DECLARE @EndTime datetime

  DECLARE @Error int

  SET @Error = 0

  ----------------------------------------------------------------------------------------------------
  --// Check input parameters                                                                     //--
  ----------------------------------------------------------------------------------------------------

  IF @Command IS NULL OR @Command = ''
  BEGIN
    SET @ErrorMessage = 'The value for parameter @Command is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @Comment IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @Comment is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @Mode NOT IN(1,2) OR @Mode IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @Mode is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @Execute NOT IN('Y','N') OR @Execute IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @Execute is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  ----------------------------------------------------------------------------------------------------
  --// Check error variable                                                                       //--
  ----------------------------------------------------------------------------------------------------

  IF @Error <> 0 GOTO ReturnCode

  ----------------------------------------------------------------------------------------------------
  --// Log initial information                                                                    //--
  ----------------------------------------------------------------------------------------------------

  SET @StartTime = CONVERT(datetime,CONVERT(nvarchar,GETDATE(),120),120)

  SET @StartMessage = 'DateTime: ' + CONVERT(nvarchar,@StartTime,120) + CHAR(13) + CHAR(10)
  SET @StartMessage = @StartMessage + 'Command: ' + @Command
  IF @Comment <> '' SET @StartMessage = @StartMessage + CHAR(13) + CHAR(10) + 'Comment: ' + @Comment
  SET @StartMessage = REPLACE(@StartMessage,'%','%%')
  RAISERROR(@StartMessage,10,1) WITH NOWAIT

  ----------------------------------------------------------------------------------------------------
  --// Execute command                                                                            //--
  ----------------------------------------------------------------------------------------------------

  IF @Mode = 1 AND @Execute = 'Y'
  BEGIN
    EXECUTE(@Command)
    SET @Error = @@ERROR
  END

  IF @Mode = 2 AND @Execute = 'Y'
  BEGIN
    BEGIN TRY
      EXECUTE(@Command)
    END TRY
    BEGIN CATCH
      SET @Error = ERROR_NUMBER()
      SET @ErrorMessage = 'Msg ' + CAST(ERROR_NUMBER() AS nvarchar) + ', ' + ISNULL(ERROR_MESSAGE(),'')
      RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    END CATCH
  END

  ----------------------------------------------------------------------------------------------------
  --// Log completing information                                                                 //--
  ----------------------------------------------------------------------------------------------------

  SET @EndTime = CONVERT(datetime,CONVERT(varchar,GETDATE(),120),120)

  SET @EndMessage = 'Outcome: ' + CASE WHEN @Execute = 'N' THEN 'Not Executed' WHEN @Error = 0 THEN 'Succeeded' ELSE 'Failed' END + CHAR(13) + CHAR(10)
  SET @EndMessage = @EndMessage + 'Duration: ' + CASE WHEN DATEDIFF(ss,@StartTime, @EndTime)/(24*3600) > 0 THEN CAST(DATEDIFF(ss,@StartTime, @EndTime)/(24*3600) AS nvarchar) + '.' ELSE '' END + CONVERT(nvarchar,@EndTime - @StartTime,108) + CHAR(13) + CHAR(10)
  SET @EndMessage = @EndMessage + 'DateTime: ' + CONVERT(nvarchar,@EndTime,120) + CHAR(13) + CHAR(10)
  SET @EndMessage = REPLACE(@EndMessage,'%','%%')
  RAISERROR(@EndMessage,10,1) WITH NOWAIT

  ----------------------------------------------------------------------------------------------------
  --// Return code                                                                                //--
  ----------------------------------------------------------------------------------------------------

  ReturnCode:

  RETURN @Error

  ----------------------------------------------------------------------------------------------------

END
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[DatabaseBackup]

@Databases nvarchar(max),
@Directory nvarchar(max) = NULL,
@BackupType nvarchar(max),
@Verify nvarchar(max) = 'N',
@CleanupTime int = NULL,
@Compress nvarchar(max) = 'N',
@CopyOnly nvarchar(max) = 'N',
@ChangeBackupType nvarchar(max) = 'N',
@BackupSoftware nvarchar(max) = NULL,
@CheckSum nvarchar(max) = 'N',
@Execute nvarchar(max) = 'Y'

AS

BEGIN

  ----------------------------------------------------------------------------------------------------
  --// Set options                                                                                //--
  ----------------------------------------------------------------------------------------------------

  SET NOCOUNT ON

  ----------------------------------------------------------------------------------------------------
  --// Declare variables                                                                          //--
  ----------------------------------------------------------------------------------------------------

  DECLARE @StartMessage nvarchar(max)
  DECLARE @EndMessage nvarchar(max)
  DECLARE @DatabaseMessage nvarchar(max)
  DECLARE @ErrorMessage nvarchar(max)

  DECLARE @DefaultDirectory nvarchar(4000)

  DECLARE @CurrentID int
  DECLARE @CurrentDatabase nvarchar(max)
  DECLARE @CurrentBackupType nvarchar(max)
  DECLARE @CurrentFileExtension nvarchar(max)
  DECLARE @CurrentDifferentialLSN numeric(25,0)
  DECLARE @CurrentLogLSN numeric(25,0)
  DECLARE @CurrentLatestBackup datetime
  DECLARE @CurrentDatabaseFS nvarchar(max)
  DECLARE @CurrentDirectory nvarchar(max)
  DECLARE @CurrentDate datetime
  DECLARE @CurrentFileName nvarchar(max)
  DECLARE @CurrentFilePath nvarchar(max)
  DECLARE @CurrentCleanupDate datetime

  DECLARE @CurrentCommand01 nvarchar(max)
  DECLARE @CurrentCommand02 nvarchar(max)
  DECLARE @CurrentCommand03 nvarchar(max)
  DECLARE @CurrentCommand04 nvarchar(max)

  DECLARE @CurrentCommandOutput01 int
  DECLARE @CurrentCommandOutput02 int
  DECLARE @CurrentCommandOutput03 int
  DECLARE @CurrentCommandOutput04 int

  DECLARE @DirectoryInfoCommand nvarchar(max)

  DECLARE @DirectoryInfo TABLE (FileExists bit,
                                FileIsADirectory bit,
                                ParentDirectoryExists bit)

  DECLARE @tmpDatabases TABLE (ID int IDENTITY PRIMARY KEY,
                               DatabaseName nvarchar(max),
                               Completed bit)

  DECLARE @Error int

  SET @Error = 0

  ----------------------------------------------------------------------------------------------------
  --// Log initial information                                                                    //--
  ----------------------------------------------------------------------------------------------------

  SET @StartMessage = 'DateTime: ' + CONVERT(nvarchar,GETDATE(),120) + CHAR(13) + CHAR(10)
  SET @StartMessage = @StartMessage + 'Server: ' + CAST(SERVERPROPERTY('ServerName') AS nvarchar) + CHAR(13) + CHAR(10)
  SET @StartMessage = @StartMessage + 'Version: ' + CAST(SERVERPROPERTY('ProductVersion') AS nvarchar) + CHAR(13) + CHAR(10)
  SET @StartMessage = @StartMessage + 'Edition: ' + CAST(SERVERPROPERTY('Edition') AS nvarchar) + CHAR(13) + CHAR(10)
  SET @StartMessage = @StartMessage + 'Procedure: ' + QUOTENAME(DB_NAME(DB_ID())) + '.' + (SELECT QUOTENAME(sys.schemas.name) FROM sys.schemas INNER JOIN sys.objects ON sys.schemas.[schema_id] = sys.objects.[schema_id] WHERE [object_id] = @@PROCID) + '.' + QUOTENAME(OBJECT_NAME(@@PROCID)) + CHAR(13) + CHAR(10)
  SET @StartMessage = @StartMessage + 'Parameters: @Databases = ' + ISNULL('''' + REPLACE(@Databases,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @Directory = ' + ISNULL('''' + REPLACE(@Directory,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @BackupType = ' + ISNULL('''' + REPLACE(@BackupType,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @Verify = ' + ISNULL('''' + REPLACE(@Verify,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @CleanupTime = ' + ISNULL(CAST(@CleanupTime AS nvarchar),'NULL')
  SET @StartMessage = @StartMessage + ', @Compress = ' + ISNULL('''' + REPLACE(@Compress,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @CopyOnly = ' + ISNULL('''' + REPLACE(@CopyOnly,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @ChangeBackupType = ' + ISNULL('''' + REPLACE(@ChangeBackupType,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @BackupSoftware = ' + ISNULL('''' + REPLACE(@BackupSoftware,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @CheckSum = ' + ISNULL('''' + REPLACE(@CheckSum,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @Execute = ' + ISNULL('''' + REPLACE(@Execute,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + CHAR(13) + CHAR(10)
  SET @StartMessage = REPLACE(@StartMessage,'%','%%')
  RAISERROR(@StartMessage,10,1) WITH NOWAIT

  ----------------------------------------------------------------------------------------------------
  --// Select databases                                                                           //--
  ----------------------------------------------------------------------------------------------------

  IF @Databases IS NULL OR @Databases = ''
  BEGIN
    SET @ErrorMessage = 'The value for parameter @Databases is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  INSERT INTO @tmpDatabases (DatabaseName, Completed)
  SELECT DatabaseName AS DatabaseName,
         0 AS Completed
  FROM dbo.DatabaseSelect (@Databases)
  ORDER BY DatabaseName ASC

  IF @@ERROR <> 0 OR (@@ROWCOUNT = 0 AND @Databases <> 'USER_DATABASES')
  BEGIN
    SET @ErrorMessage = 'Error selecting databases.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  SET @ErrorMessage = ''
  SELECT @ErrorMessage = @ErrorMessage + QUOTENAME(DatabaseName) + ', '
  FROM @tmpDatabases
  WHERE REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(DatabaseName,'\',''),'/',''),':',''),'*',''),'?',''),'"',''),'<',''),'>',''),'|',''),' ','') = ''
  IF @@ROWCOUNT > 0
  BEGIN
    SET @ErrorMessage = 'The names of the following databases are not supported; ' + LEFT(@ErrorMessage,LEN(@ErrorMessage)-1) + '.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  ----------------------------------------------------------------------------------------------------
  --// Get default backup directory.                                                              //--
  ----------------------------------------------------------------------------------------------------

  IF @Directory IS NULL
  BEGIN
    EXECUTE [master].dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\MSSQLServer', N'BackupDirectory', @DefaultDirectory OUTPUT
    SET @Directory = @DefaultDirectory
  END

  ----------------------------------------------------------------------------------------------------
  --// Check directory                                                                            //--
  ----------------------------------------------------------------------------------------------------

  IF NOT (@Directory LIKE '_:' OR @Directory LIKE '_:\%' OR @Directory LIKE '\\%\%') OR @Directory IS NULL OR LEFT(@Directory,1) = ' ' OR RIGHT(@Directory,1) = ' '
  BEGIN
    SET @ErrorMessage = 'The value for parameter @Directory is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  SET @DirectoryInfoCommand = 'EXECUTE xp_fileexist N''' + REPLACE(@Directory,'''','''''') + ''''

  INSERT INTO @DirectoryInfo (FileExists, FileIsADirectory, ParentDirectoryExists)
  EXECUTE(@DirectoryInfoCommand)

  IF NOT EXISTS (SELECT * FROM @DirectoryInfo WHERE FileExists = 0 AND FileIsADirectory = 1 AND ParentDirectoryExists = 1)
  BEGIN
    SET @ErrorMessage = 'The directory does not exist.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  ----------------------------------------------------------------------------------------------------
  --// Check input parameters                                                                     //--
  ----------------------------------------------------------------------------------------------------

  IF @BackupType NOT IN ('FULL','DIFF','LOG') OR @BackupType IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @BackupType is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @Verify NOT IN ('Y','N') OR @Verify IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @Verify is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @CleanupTime < 0
  BEGIN
    SET @ErrorMessage = 'The value for parameter @CleanupTime is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @Compress NOT IN ('Y','N') OR @Compress IS NULL OR (@Compress = 'Y' AND NOT (SERVERPROPERTY('EngineEdition') = 3 AND CAST(LEFT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar), CHARINDEX('.',CAST(SERVERPROPERTY('ProductVersion') AS nvarchar)) - 1) AS int) >= 10))
  BEGIN
    SET @ErrorMessage = 'The value for parameter @Compress is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @Compress = 'Y' AND NOT (SERVERPROPERTY('EngineEdition') = 3 AND CAST(LEFT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar), CHARINDEX('.',CAST(SERVERPROPERTY('ProductVersion') AS nvarchar)) - 1) AS int) >= 10)
  BEGIN
    SET @ErrorMessage = 'Backup compression is only supported in SQL Server 2008 Enterprise and Developer Edition.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @CopyOnly NOT IN ('Y','N') OR @CopyOnly IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @CopyOnly is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @ChangeBackupType NOT IN ('Y','N') OR @ChangeBackupType IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @ChangeBackupType is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @BackupSoftware NOT IN ('LITESPEED') OR (@BackupSoftware = 'LITESPEED' AND NOT EXISTS (SELECT * FROM [master].sys.objects WHERE [type] = 'X' AND [name] = 'xp_sqllitespeed_version'))
  BEGIN
    SET @ErrorMessage = 'The value for parameter @BackupSoftware is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @BackupSoftware = 'LITESPEED' AND NOT EXISTS (SELECT * FROM [master].sys.objects WHERE [type] = 'X' AND [name] = 'xp_sqllitespeed_version')
  BEGIN
    SET @ErrorMessage = 'LiteSpeed is not installed.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @CheckSum NOT IN ('Y','N') OR @CheckSum IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @CheckSum is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @Execute NOT IN('Y','N') OR @Execute IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @Execute is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  ----------------------------------------------------------------------------------------------------
  --// Check error variable                                                                       //--
  ----------------------------------------------------------------------------------------------------

  IF @Error <> 0 GOTO Logging

  ----------------------------------------------------------------------------------------------------
  --// Execute backup commands                                                                    //--
  ----------------------------------------------------------------------------------------------------

  WHILE EXISTS (SELECT * FROM @tmpDatabases WHERE Completed = 0)
  BEGIN

    SELECT TOP 1 @CurrentID = ID,
                 @CurrentDatabase = DatabaseName
    FROM @tmpDatabases
    WHERE Completed = 0
    ORDER BY ID ASC

    SELECT @CurrentDifferentialLSN = differential_base_lsn
    FROM sys.master_files
    WHERE database_id = DB_ID(@CurrentDatabase)
    AND [type] = 0
    AND [file_id] = 1

    -- Workaround for a bug in SQL Server 2005
    IF CAST(LEFT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar), CHARINDEX('.',CAST(SERVERPROPERTY('ProductVersion') AS nvarchar)) - 1) AS int) = 9
    AND (SELECT differential_base_lsn FROM sys.master_files WHERE database_id = DB_ID(@CurrentDatabase) AND [type] = 0 AND [file_id] = 1) = (SELECT differential_base_lsn FROM sys.master_files WHERE database_id = DB_ID('model') AND [type] = 0 AND [file_id] = 1)
    AND (SELECT differential_base_guid FROM sys.master_files WHERE database_id = DB_ID(@CurrentDatabase) AND [type] = 0 AND [file_id] = 1) = (SELECT differential_base_guid FROM sys.master_files WHERE database_id = DB_ID('model') AND [type] = 0 AND [file_id] = 1)
    AND (SELECT differential_base_time FROM sys.master_files WHERE database_id = DB_ID(@CurrentDatabase) AND [type] = 0 AND [file_id] = 1) IS NULL
    BEGIN
      SET @CurrentDifferentialLSN = NULL
    END

    SELECT @CurrentLogLSN = last_log_backup_lsn
    FROM sys.database_recovery_status
    WHERE database_id = DB_ID(@CurrentDatabase)

    SET @CurrentBackupType = @BackupType

    IF @ChangeBackupType = 'Y'
    BEGIN
      IF @CurrentBackupType = 'LOG' AND DATABASEPROPERTYEX(@CurrentDatabase,'recovery') <> 'SIMPLE' AND @CurrentLogLSN IS NULL AND @CurrentDatabase <> 'master'
      BEGIN
        SET @CurrentBackupType = 'DIFF'
      END
      IF @CurrentBackupType = 'DIFF' AND @CurrentDifferentialLSN IS NULL AND @CurrentDatabase <> 'master'
      BEGIN
        SET @CurrentBackupType = 'FULL'
      END
    END

    SELECT @CurrentLatestBackup = MAX(backup_finish_date)
    FROM msdb.dbo.backupset
    WHERE [type] IN('D','I')
    AND database_name = @CurrentDatabase

    -- Set database message
    SET @DatabaseMessage = 'DateTime: ' + CONVERT(nvarchar,GETDATE(),120) + CHAR(13) + CHAR(10)
    SET @DatabaseMessage = @DatabaseMessage + 'Database: ' + QUOTENAME(@CurrentDatabase) + CHAR(13) + CHAR(10)
    SET @DatabaseMessage = @DatabaseMessage + 'Status: ' + CAST(DATABASEPROPERTYEX(@CurrentDatabase,'status') AS nvarchar) + CHAR(13) + CHAR(10)
    SET @DatabaseMessage = @DatabaseMessage + 'Standby: ' + CASE WHEN DATABASEPROPERTYEX(@CurrentDatabase,'IsInStandBy') = 1 THEN 'Yes' ELSE 'No' END + CHAR(13) + CHAR(10)
    SET @DatabaseMessage = @DatabaseMessage + 'Recovery model: ' + CAST(DATABASEPROPERTYEX(@CurrentDatabase,'recovery') AS nvarchar) + CHAR(13) + CHAR(10)
    SET @DatabaseMessage = @DatabaseMessage + 'Differential base LSN: ' + ISNULL(CAST(@CurrentDifferentialLSN AS nvarchar),'NULL') + CHAR(13) + CHAR(10)
    SET @DatabaseMessage = @DatabaseMessage + 'Last log backup LSN: ' + ISNULL(CAST(@CurrentLogLSN AS nvarchar),'NULL') + CHAR(13) + CHAR(10)
    SET @DatabaseMessage = REPLACE(@DatabaseMessage,'%','%%')
    RAISERROR(@DatabaseMessage,10,1) WITH NOWAIT

    IF DATABASEPROPERTYEX(@CurrentDatabase,'status') = 'ONLINE'
    AND DATABASEPROPERTYEX(@CurrentDatabase,'IsInStandBy') = 0
    AND NOT (@CurrentBackupType = 'LOG' AND (DATABASEPROPERTYEX(@CurrentDatabase,'recovery') = 'SIMPLE' OR @CurrentLogLSN IS NULL))
    AND NOT (@CurrentBackupType = 'DIFF' AND @CurrentDifferentialLSN IS NULL)
    AND NOT (@CurrentBackupType IN('DIFF','LOG') AND @CurrentDatabase = 'master')
    BEGIN

      -- Set variables
      SET @CurrentDate = GETDATE()

      IF @CleanupTime IS NULL OR (@CurrentBackupType = 'LOG' AND @CurrentLatestBackup IS NULL)
      BEGIN
        SET @CurrentCleanupDate = NULL
      END
      ELSE
      IF @CurrentBackupType = 'LOG'
      BEGIN
        SET @CurrentCleanupDate = (SELECT MIN([Date]) FROM(SELECT DATEADD(hh,-(@CleanupTime),@CurrentDate) AS [Date] UNION SELECT @CurrentLatestBackup AS [Date]) Dates)
      END
      ELSE
      BEGIN
        SET @CurrentCleanupDate = DATEADD(hh,-(@CleanupTime),@CurrentDate)
      END

      SET @CurrentDatabaseFS = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@CurrentDatabase,'\',''),'/',''),':',''),'*',''),'?',''),'"',''),'<',''),'>',''),'|',''),' ','')

      SELECT @CurrentFileExtension = CASE
      WHEN @CurrentBackupType = 'FULL' THEN 'bak'
      WHEN @CurrentBackupType = 'DIFF' THEN 'bak'
      WHEN @CurrentBackupType = 'LOG' THEN 'trn'
      END

      SET @CurrentFileName = REPLACE(CAST(SERVERPROPERTY('servername') AS nvarchar),'\','$') + '_' + @CurrentDatabaseFS + '_' + UPPER(@CurrentBackupType) + '_' + REPLACE(REPLACE(REPLACE((CONVERT(nvarchar,@CurrentDate,120)),'-',''),' ','_'),':','') + '.' + @CurrentFileExtension

      SET @CurrentDirectory = @Directory + CASE WHEN RIGHT(@Directory,1) = '\' THEN '' ELSE '\' END + REPLACE(CAST(SERVERPROPERTY('servername') AS nvarchar),'\','$') + '\' + @CurrentDatabaseFS + '\' + UPPER(@CurrentBackupType)

      SET @CurrentFilePath = @CurrentDirectory + '\' + @CurrentFileName

      -- Create directory
      SET @CurrentCommand01 = 'DECLARE @ReturnCode int EXECUTE @ReturnCode = master.dbo.xp_create_subdir N''' + REPLACE(@CurrentDirectory,'''','''''') + ''' IF @ReturnCode <> 0 RAISERROR(''Error creating directory.'', 16, 1)'
      EXECUTE @CurrentCommandOutput01 = [dbo].[CommandExecute] @CurrentCommand01, '', 1, @Execute
      SET @Error = @@ERROR
      IF @Error <> 0 SET @CurrentCommandOutput01 = @Error

      -- Perform a backup
      IF @CurrentCommandOutput01 = 0
      BEGIN
        IF @BackupSoftware IS NULL
        BEGIN
          SELECT @CurrentCommand02 = CASE
          WHEN @CurrentBackupType IN('DIFF','FULL') THEN 'BACKUP DATABASE ' + QUOTENAME(@CurrentDatabase) + ' TO DISK = N''' + REPLACE(@CurrentFilePath,'''','''''') + ''''
          WHEN @CurrentBackupType = 'LOG' THEN 'BACKUP LOG ' + QUOTENAME(@CurrentDatabase) + ' TO DISK = N''' + REPLACE(@CurrentFilePath,'''','''''') + ''''
          END
          SET @CurrentCommand02 = @CurrentCommand02 + ' WITH '
          IF @CheckSum = 'Y' SET @CurrentCommand02 = @CurrentCommand02 + 'CHECKSUM'
          IF @CheckSum = 'N' SET @CurrentCommand02 = @CurrentCommand02 + 'NO_CHECKSUM'
          IF @Compress = 'Y' SET @CurrentCommand02 = @CurrentCommand02 + ', COMPRESSION'
          IF @Compress = 'N' AND CAST(LEFT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar), CHARINDEX('.',CAST(SERVERPROPERTY('ProductVersion') AS nvarchar)) - 1) AS int) >= 10 SET @CurrentCommand02 = @CurrentCommand02 + ', NO_COMPRESSION'
          IF @CurrentBackupType = 'DIFF' SET @CurrentCommand02 = @CurrentCommand02 + ', DIFFERENTIAL'
          IF @CopyOnly = 'Y' SET @CurrentCommand02 = @CurrentCommand02 + ', COPY_ONLY'
        END

        IF @BackupSoftware = 'LITESPEED'
        BEGIN
          SELECT @CurrentCommand02 = CASE
          WHEN @CurrentBackupType IN('DIFF','FULL') THEN 'DECLARE @ReturnCode int EXECUTE @ReturnCode = master.dbo.xp_backup_database @database = N''' + REPLACE(@CurrentDatabase,'''','''''') + ''', @filename = N''' + REPLACE(@CurrentFilePath,'''','''''') + ''''
          WHEN @CurrentBackupType = 'LOG' THEN 'DECLARE @ReturnCode int EXECUTE @ReturnCode = master.dbo.xp_backup_log @database = N''' + REPLACE(@CurrentDatabase,'''','''''') + ''', @filename = N''' + REPLACE(@CurrentFilePath,'''','''''') + ''''
          END
          SET @CurrentCommand02 = @CurrentCommand02 + ', @with = '''
          IF @CheckSum = 'Y' SET @CurrentCommand02 = @CurrentCommand02 + 'CHECKSUM'
          IF @CheckSum = 'N' SET @CurrentCommand02 = @CurrentCommand02 + 'NO_CHECKSUM'
          IF @CurrentBackupType = 'DIFF' SET @CurrentCommand02 = @CurrentCommand02 + ', DIFFERENTIAL'
          IF @CopyOnly = 'Y' SET @CurrentCommand02 = @CurrentCommand02 + ', COPY_ONLY'
          SET @CurrentCommand02 = @CurrentCommand02 + ''' IF @ReturnCode <> 0 RAISERROR(''Error performing LiteSpeed backup.'', 16, 1)'
        END

        EXECUTE @CurrentCommandOutput02 = [dbo].[CommandExecute] @CurrentCommand02, '', 1, @Execute
        SET @Error = @@ERROR
        IF @Error <> 0 SET @CurrentCommandOutput02 = @Error
      END

      -- Verify the backup
      IF @CurrentCommandOutput02 = 0 AND @Verify = 'Y'
      BEGIN
        IF @BackupSoftware IS NULL
        BEGIN
          SET @CurrentCommand03 = 'RESTORE VERIFYONLY FROM DISK = ''' + REPLACE(@CurrentFilePath,'''','''''') + ''''
        END

        IF @BackupSoftware = 'LITESPEED'
        BEGIN
          SET @CurrentCommand03 = 'DECLARE @ReturnCode int EXECUTE @ReturnCode = master.dbo.xp_restore_verifyonly @filename = N''' + REPLACE(@CurrentFilePath,'''','''''') + ''' IF @ReturnCode <> 0 RAISERROR(''Error verifying LiteSpeed backup.'', 16, 1)'
        END

        EXECUTE @CurrentCommandOutput03 = [dbo].[CommandExecute] @CurrentCommand03, '', 1, @Execute
        SET @Error = @@ERROR
        IF @Error <> 0 SET @CurrentCommandOutput03 = @Error
      END

      -- Delete old backup files
      IF (@CurrentCommandOutput02 = 0 AND @Verify = 'N' AND @CurrentCleanupDate IS NOT NULL)
      OR (@CurrentCommandOutput02 = 0 AND @Verify = 'Y' AND @CurrentCommandOutput03 = 0 AND @CurrentCleanupDate IS NOT NULL)
      BEGIN
        IF @BackupSoftware IS NULL
        BEGIN
          SET @CurrentCommand04 = 'DECLARE @ReturnCode int EXECUTE @ReturnCode = master.dbo.xp_delete_file 0, N''' + REPLACE(@CurrentDirectory,'''','''''') + ''', ''' + @CurrentFileExtension + ''', ''' + CONVERT(nvarchar(19),@CurrentCleanupDate,126) + ''' IF @ReturnCode <> 0 RAISERROR(''Error deleting files.'', 16, 1)'
        END

        IF @BackupSoftware = 'LITESPEED'
        BEGIN
          SET @CurrentCommand04 = 'DECLARE @ReturnCode int EXECUTE @ReturnCode = master.dbo.xp_slssqlmaint N''-MAINTDEL -DELFOLDER "' + REPLACE(@CurrentDirectory,'''','''''') + '" -DELEXTENSION "' + @CurrentFileExtension + '" -DELUNIT "' + CAST(DATEDIFF(mi,@CurrentCleanupDate,GETDATE()) + 1 AS nvarchar) + '" -DELUNITTYPE "minutes" -DELUSEAGE'' IF @ReturnCode <> 0 RAISERROR(''Error deleting LiteSpeed backup files.'', 16, 1)'
        END

        EXECUTE @CurrentCommandOutput04 = [dbo].[CommandExecute] @CurrentCommand04, '', 1, @Execute
        SET @Error = @@ERROR
        IF @Error <> 0 SET @CurrentCommandOutput04 = @Error
      END

    END

    -- Update that the database is completed
    UPDATE @tmpDatabases
    SET Completed = 1
    WHERE ID = @CurrentID

    -- Clear variables
    SET @CurrentID = NULL
    SET @CurrentDatabase = NULL
    SET @CurrentBackupType = NULL
    SET @CurrentFileExtension = NULL
    SET @CurrentDifferentialLSN = NULL
    SET @CurrentLogLSN = NULL
    SET @CurrentLatestBackup = NULL
    SET @CurrentDatabaseFS = NULL
    SET @CurrentDirectory = NULL
    SET @CurrentDate = NULL
    SET @CurrentFileName = NULL
    SET @CurrentFilePath = NULL
    SET @CurrentCleanupDate = NULL

    SET @CurrentCommand01 = NULL
    SET @CurrentCommand02 = NULL
    SET @CurrentCommand03 = NULL
    SET @CurrentCommand04 = NULL

    SET @CurrentCommandOutput01 = NULL
    SET @CurrentCommandOutput02 = NULL
    SET @CurrentCommandOutput03 = NULL
    SET @CurrentCommandOutput04 = NULL

  END

  ----------------------------------------------------------------------------------------------------
  --// Log completing information                                                                 //--
  ----------------------------------------------------------------------------------------------------

  Logging:
  SET @EndMessage = 'DateTime: ' + CONVERT(nvarchar,GETDATE(),120)
  SET @EndMessage = REPLACE(@EndMessage,'%','%%')
  RAISERROR(@EndMessage,10,1) WITH NOWAIT

  ----------------------------------------------------------------------------------------------------

END
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[DatabaseIntegrityCheck]

@Databases nvarchar(max),
@PhysicalOnly nvarchar(max) = 'N',
@NoIndex nvarchar(max) = 'N',
@ExtendedLogicalChecks nvarchar(max) = 'N',
@Execute nvarchar(max) = 'Y'

AS

BEGIN

  ----------------------------------------------------------------------------------------------------
  --// Set options                                                                                //--
  ----------------------------------------------------------------------------------------------------

  SET NOCOUNT ON

  ----------------------------------------------------------------------------------------------------
  --// Declare variables                                                                          //--
  ----------------------------------------------------------------------------------------------------

  DECLARE @StartMessage nvarchar(max)
  DECLARE @EndMessage nvarchar(max)
  DECLARE @DatabaseMessage nvarchar(max)
  DECLARE @ErrorMessage nvarchar(max)

  DECLARE @CurrentID int
  DECLARE @CurrentDatabase nvarchar(max)

  DECLARE @CurrentCommand01 nvarchar(max)

  DECLARE @CurrentCommandOutput01 int

  DECLARE @tmpDatabases TABLE (ID int IDENTITY PRIMARY KEY,
                               DatabaseName nvarchar(max),
                               Completed bit)

  DECLARE @Error int

  SET @Error = 0

  ----------------------------------------------------------------------------------------------------
  --// Log initial information                                                                    //--
  ----------------------------------------------------------------------------------------------------

  SET @StartMessage = 'DateTime: ' + CONVERT(nvarchar,GETDATE(),120) + CHAR(13) + CHAR(10)
  SET @StartMessage = @StartMessage + 'Server: ' + CAST(SERVERPROPERTY('ServerName') AS nvarchar) + CHAR(13) + CHAR(10)
  SET @StartMessage = @StartMessage + 'Version: ' + CAST(SERVERPROPERTY('ProductVersion') AS nvarchar) + CHAR(13) + CHAR(10)
  SET @StartMessage = @StartMessage + 'Edition: ' + CAST(SERVERPROPERTY('Edition') AS nvarchar) + CHAR(13) + CHAR(10)
  SET @StartMessage = @StartMessage + 'Procedure: ' + QUOTENAME(DB_NAME(DB_ID())) + '.' + (SELECT QUOTENAME(sys.schemas.name) FROM sys.schemas INNER JOIN sys.objects ON sys.schemas.[schema_id] = sys.objects.[schema_id] WHERE [object_id] = @@PROCID) + '.' + QUOTENAME(OBJECT_NAME(@@PROCID)) + CHAR(13) + CHAR(10)
  SET @StartMessage = @StartMessage + 'Parameters: @Databases = ' + ISNULL('''' + REPLACE(@Databases,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @PhysicalOnly = ' + ISNULL('''' + REPLACE(@PhysicalOnly,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @NoIndex = ' + ISNULL('''' + REPLACE(@NoIndex,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @ExtendedLogicalChecks = ' + ISNULL('''' + REPLACE(@ExtendedLogicalChecks,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @Execute = ' + ISNULL('''' + REPLACE(@Execute,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + CHAR(13) + CHAR(10)
  SET @StartMessage = REPLACE(@StartMessage,'%','%%')
  RAISERROR(@StartMessage,10,1) WITH NOWAIT

  ----------------------------------------------------------------------------------------------------
  --// Select databases                                                                           //--
  ----------------------------------------------------------------------------------------------------

  IF @Databases IS NULL OR @Databases = ''
  BEGIN
    SET @ErrorMessage = 'The value for parameter @Databases is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  INSERT INTO @tmpDatabases (DatabaseName, Completed)
  SELECT DatabaseName AS DatabaseName,
         0 AS Completed
  FROM dbo.DatabaseSelect (@Databases)
  ORDER BY DatabaseName ASC

  IF @@ERROR <> 0 OR (@@ROWCOUNT = 0 AND @Databases <> 'USER_DATABASES')
  BEGIN
    SET @ErrorMessage = 'Error selecting databases.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  ----------------------------------------------------------------------------------------------------
  --// Check input parameters                                                                     //--
  ----------------------------------------------------------------------------------------------------

  IF @PhysicalOnly NOT IN ('Y','N') OR @PhysicalOnly IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @PhysicalOnly is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @NoIndex NOT IN ('Y','N') OR @NoIndex IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @NoIndex is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @ExtendedLogicalChecks NOT IN ('Y','N') OR @ExtendedLogicalChecks IS NULL OR (@ExtendedLogicalChecks = 'Y' AND NOT (CAST(LEFT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar), CHARINDEX('.',CAST(SERVERPROPERTY('ProductVersion') AS nvarchar)) - 1) AS int) >= 10))
  BEGIN
    SET @ErrorMessage = 'The value for parameter @ExtendedLogicalChecks is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF (@ExtendedLogicalChecks = 'Y' AND NOT (CAST(LEFT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar), CHARINDEX('.',CAST(SERVERPROPERTY('ProductVersion') AS nvarchar)) - 1) AS int) >= 10))
  BEGIN
    SET @ErrorMessage = 'Extended logical checks are only supported in SQL Server 2008.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @Execute NOT IN('Y','N') OR @Execute IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @Execute is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  ----------------------------------------------------------------------------------------------------
  --// Check error variable                                                                       //--
  ----------------------------------------------------------------------------------------------------

  IF @Error <> 0 GOTO Logging

  ----------------------------------------------------------------------------------------------------
  --// Execute commands                                                                           //--
  ----------------------------------------------------------------------------------------------------

  WHILE EXISTS (SELECT * FROM @tmpDatabases WHERE Completed = 0)
  BEGIN

    SELECT TOP 1 @CurrentID = ID,
                 @CurrentDatabase = DatabaseName
    FROM @tmpDatabases
    WHERE Completed = 0
    ORDER BY ID ASC

    -- Set database message
    SET @DatabaseMessage = 'DateTime: ' + CONVERT(nvarchar,GETDATE(),120) + CHAR(13) + CHAR(10)
    SET @DatabaseMessage = @DatabaseMessage + 'Database: ' + QUOTENAME(@CurrentDatabase) + CHAR(13) + CHAR(10)
    SET @DatabaseMessage = @DatabaseMessage + 'Status: ' + CAST(DATABASEPROPERTYEX(@CurrentDatabase,'status') AS nvarchar) + CHAR(13) + CHAR(10)
    SET @DatabaseMessage = REPLACE(@DatabaseMessage,'%','%%')
    RAISERROR(@DatabaseMessage,10,1) WITH NOWAIT

    IF DATABASEPROPERTYEX(@CurrentDatabase,'status') = 'ONLINE'
    BEGIN
      SET @CurrentCommand01 = 'DBCC CHECKDB (' + QUOTENAME(@CurrentDatabase)
      IF @NoIndex = 'Y' SET @CurrentCommand01 = @CurrentCommand01 + ', NOINDEX'
      SET @CurrentCommand01 = @CurrentCommand01 + ') WITH NO_INFOMSGS, ALL_ERRORMSGS'
      IF @PhysicalOnly = 'N' SET @CurrentCommand01 = @CurrentCommand01 + ', DATA_PURITY'
      IF @PhysicalOnly = 'Y' SET @CurrentCommand01 = @CurrentCommand01 + ', PHYSICAL_ONLY'
      IF @ExtendedLogicalChecks = 'Y' SET @CurrentCommand01 = @CurrentCommand01 + ', EXTENDED_LOGICAL_CHECKS'

      EXECUTE @CurrentCommandOutput01 = [dbo].[CommandExecute] @CurrentCommand01, '', 1, @Execute
      SET @Error = @@ERROR
      IF @Error <> 0 SET @CurrentCommandOutput01 = @Error
    END

    -- Update that the database is completed
    UPDATE @tmpDatabases
    SET Completed = 1
    WHERE ID = @CurrentID

    -- Clear variables
    SET @CurrentID = NULL
    SET @CurrentDatabase = NULL

    SET @CurrentCommand01 = NULL

    SET @CurrentCommandOutput01 = NULL

  END

  ----------------------------------------------------------------------------------------------------
  --// Log completing information                                                                 //--
  ----------------------------------------------------------------------------------------------------

  Logging:
  SET @EndMessage = 'DateTime: ' + CONVERT(nvarchar,GETDATE(),120)
  SET @EndMessage = REPLACE(@EndMessage,'%','%%')
  RAISERROR(@EndMessage,10,1) WITH NOWAIT

  ----------------------------------------------------------------------------------------------------

END
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[IndexOptimize]

@Databases nvarchar(max),
@FragmentationHigh_LOB nvarchar(max) = 'INDEX_REBUILD_OFFLINE',
@FragmentationHigh_NonLOB nvarchar(max) = 'INDEX_REBUILD_OFFLINE',
@FragmentationMedium_LOB nvarchar(max) = 'INDEX_REORGANIZE',
@FragmentationMedium_NonLOB nvarchar(max) = 'INDEX_REORGANIZE',
@FragmentationLow_LOB nvarchar(max) = 'NOTHING',
@FragmentationLow_NonLOB nvarchar(max) = 'NOTHING',
@FragmentationLevel1 tinyint = 5,
@FragmentationLevel2 tinyint = 30,
@PageCountLevel int = 1000,
@SortInTempdb nvarchar(max) = 'N',
@MaxDOP tinyint = NULL,
@FillFactor tinyint = NULL,
@LOBCompaction nvarchar(max) = 'Y',
@StatisticsSample tinyint = NULL,
@PartitionLevel nvarchar(max) = 'N',
@TimeLimit int = NULL,
@Execute nvarchar(max) = 'Y'

AS

BEGIN

  ----------------------------------------------------------------------------------------------------
  --// Set options                                                                                //--
  ----------------------------------------------------------------------------------------------------

  SET NOCOUNT ON

  SET LOCK_TIMEOUT 3600000

  ----------------------------------------------------------------------------------------------------
  --// Declare variables                                                                          //--
  ----------------------------------------------------------------------------------------------------

  DECLARE @StartMessage nvarchar(max)
  DECLARE @EndMessage nvarchar(max)
  DECLARE @DatabaseMessage nvarchar(max)
  DECLARE @ErrorMessage nvarchar(max)

  DECLARE @StartTime datetime

  DECLARE @CurrentID int
  DECLARE @CurrentDatabase nvarchar(max)

  DECLARE @CurrentCommandSelect01 nvarchar(max)
  DECLARE @CurrentCommandSelect02 nvarchar(max)
  DECLARE @CurrentCommandSelect03 nvarchar(max)
  DECLARE @CurrentCommandSelect04 nvarchar(max)
  DECLARE @CurrentCommandSelect05 nvarchar(max)

  DECLARE @CurrentCommand01 nvarchar(max)
  DECLARE @CurrentCommand02 nvarchar(max)

  DECLARE @CurrentCommandOutput01 int
  DECLARE @CurrentCommandOutput02 int

  DECLARE @CurrentIxID int
  DECLARE @CurrentSchemaID int
  DECLARE @CurrentSchemaName nvarchar(max)
  DECLARE @CurrentObjectID int
  DECLARE @CurrentObjectName nvarchar(max)
  DECLARE @CurrentObjectType nvarchar(max)
  DECLARE @CurrentIndexID int
  DECLARE @CurrentIndexName nvarchar(max)
  DECLARE @CurrentIndexType int
  DECLARE @CurrentPartitionID bigint
  DECLARE @CurrentPartitionNumber int
  DECLARE @CurrentPartitionCount int
  DECLARE @CurrentIsPartition bit
  DECLARE @CurrentIndexExists bit
  DECLARE @CurrentIsLOB bit
  DECLARE @CurrentAllowPageLocks bit
  DECLARE @CurrentOnReadOnlyFileGroup bit
  DECLARE @CurrentFragmentationLevel float
  DECLARE @CurrentPageCount bigint
  DECLARE @CurrentAction nvarchar(max)
  DECLARE @CurrentComment nvarchar(max)

  DECLARE @tmpDatabases TABLE (ID int IDENTITY PRIMARY KEY,
                               DatabaseName nvarchar(max),
                               Completed bit)

  DECLARE @tmpIndexes TABLE (IxID int IDENTITY PRIMARY KEY,
                             SchemaID int,
                             SchemaName nvarchar(max),
                             ObjectID int,
                             ObjectName nvarchar(max),
                             ObjectType nvarchar(max),
                             IndexID int,
                             IndexName nvarchar(max),
                             IndexType int,
                             PartitionID bigint,
                             PartitionNumber int,
                             PartitionCount int,
                             Completed bit)

  DECLARE @tmpIndexExists TABLE ([Count] int)

  DECLARE @tmpIsLOB TABLE ([Count] int)

  DECLARE @tmpAllowPageLocks TABLE ([Count] int)

  DECLARE @tmpOnReadOnlyFileGroup TABLE ([Count] int)

  DECLARE @Actions TABLE ([Action] nvarchar(max))

  INSERT INTO @Actions([Action]) VALUES('INDEX_REBUILD_ONLINE')
  INSERT INTO @Actions([Action]) VALUES('INDEX_REBUILD_OFFLINE')
  INSERT INTO @Actions([Action]) VALUES('INDEX_REORGANIZE')
  INSERT INTO @Actions([Action]) VALUES('STATISTICS_UPDATE')
  INSERT INTO @Actions([Action]) VALUES('INDEX_REORGANIZE_STATISTICS_UPDATE')
  INSERT INTO @Actions([Action]) VALUES('NOTHING')

  DECLARE @Error int

  SET @Error = 0

  ----------------------------------------------------------------------------------------------------
  --// Log initial information                                                                    //--
  ----------------------------------------------------------------------------------------------------

  SET @StartTime = CONVERT(datetime,CONVERT(nvarchar,GETDATE(),120),120)

  SET @StartMessage = 'DateTime: ' + CONVERT(nvarchar,@StartTime,120) + CHAR(13) + CHAR(10)
  SET @StartMessage = @StartMessage + 'Server: ' + CAST(SERVERPROPERTY('ServerName') AS nvarchar) + CHAR(13) + CHAR(10)
  SET @StartMessage = @StartMessage + 'Version: ' + CAST(SERVERPROPERTY('ProductVersion') AS nvarchar) + CHAR(13) + CHAR(10)
  SET @StartMessage = @StartMessage + 'Edition: ' + CAST(SERVERPROPERTY('Edition') AS nvarchar) + CHAR(13) + CHAR(10)
  SET @StartMessage = @StartMessage + 'Procedure: ' + QUOTENAME(DB_NAME(DB_ID())) + '.' + (SELECT QUOTENAME(sys.schemas.name) FROM sys.schemas INNER JOIN sys.objects ON sys.schemas.[schema_id] = sys.objects.[schema_id] WHERE [object_id] = @@PROCID) + '.' + QUOTENAME(OBJECT_NAME(@@PROCID)) + CHAR(13) + CHAR(10)
  SET @StartMessage = @StartMessage + 'Parameters: @Databases = ' + ISNULL('''' + REPLACE(@Databases,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @FragmentationHigh_LOB = ' + ISNULL('''' + REPLACE(@FragmentationHigh_LOB,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @FragmentationHigh_NonLOB = ' + ISNULL('''' + REPLACE(@FragmentationHigh_NonLOB,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @FragmentationMedium_LOB = ' + ISNULL('''' + REPLACE(@FragmentationMedium_LOB,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @FragmentationMedium_NonLOB = ' + ISNULL('''' + REPLACE(@FragmentationMedium_NonLOB,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @FragmentationLow_LOB = ' + ISNULL('''' + REPLACE(@FragmentationLow_LOB,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @FragmentationLow_NonLOB = ' + ISNULL('''' + REPLACE(@FragmentationLow_NonLOB,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @FragmentationLevel1 = ' + ISNULL(CAST(@FragmentationLevel1 AS nvarchar),'NULL')
  SET @StartMessage = @StartMessage + ', @FragmentationLevel2 = ' + ISNULL(CAST(@FragmentationLevel2 AS nvarchar),'NULL')
  SET @StartMessage = @StartMessage + ', @PageCountLevel = ' + ISNULL(CAST(@PageCountLevel AS nvarchar),'NULL')
  SET @StartMessage = @StartMessage + ', @SortInTempdb = ' + ISNULL('''' + REPLACE(@SortInTempdb,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @MaxDOP = ' + ISNULL(CAST(@MaxDOP AS nvarchar),'NULL')
  SET @StartMessage = @StartMessage + ', @FillFactor = ' + ISNULL(CAST(@FillFactor AS nvarchar),'NULL')
  SET @StartMessage = @StartMessage + ', @LOBCompaction = ' + ISNULL('''' + REPLACE(@LOBCompaction,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @StatisticsSample = ' + ISNULL(CAST(@StatisticsSample AS nvarchar),'NULL')
  SET @StartMessage = @StartMessage + ', @PartitionLevel = ' + ISNULL('''' + REPLACE(@PartitionLevel,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + ', @TimeLimit = ' + ISNULL(CAST(@TimeLimit AS nvarchar),'NULL')
  SET @StartMessage = @StartMessage + ', @Execute = ' + ISNULL('''' + REPLACE(@Execute,'''','''''') + '''','NULL')
  SET @StartMessage = @StartMessage + CHAR(13) + CHAR(10)
  SET @StartMessage = REPLACE(@StartMessage,'%','%%')
  RAISERROR(@StartMessage,10,1) WITH NOWAIT

  ----------------------------------------------------------------------------------------------------
  --// Select databases                                                                           //--
  ----------------------------------------------------------------------------------------------------

  IF @Databases IS NULL OR @Databases = ''
  BEGIN
    SET @ErrorMessage = 'The value for parameter @Databases is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  INSERT INTO @tmpDatabases (DatabaseName, Completed)
  SELECT DatabaseName AS DatabaseName,
         0 AS Completed
  FROM dbo.DatabaseSelect (@Databases)
  ORDER BY DatabaseName ASC

  IF @@ERROR <> 0 OR (@@ROWCOUNT = 0 AND @Databases <> 'USER_DATABASES')
  BEGIN
    SET @ErrorMessage = 'Error selecting databases.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  ----------------------------------------------------------------------------------------------------
  --// Check input parameters                                                                     //--
  ----------------------------------------------------------------------------------------------------

  IF @FragmentationHigh_LOB NOT IN(SELECT [Action] FROM @Actions WHERE [Action] <> 'INDEX_REBUILD_ONLINE')
  BEGIN
    SET @ErrorMessage = 'The value for parameter @FragmentationHigh_LOB is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @FragmentationHigh_NonLOB NOT IN(SELECT [Action] FROM @Actions WHERE [Action] <> 'INDEX_REBUILD_ONLINE' OR SERVERPROPERTY('EngineEdition') = 3)
  BEGIN
    SET @ErrorMessage = 'The value for parameter @FragmentationHigh_NonLOB is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @FragmentationMedium_LOB NOT IN(SELECT [Action] FROM @Actions WHERE [Action] <> 'INDEX_REBUILD_ONLINE')
  BEGIN
    SET @ErrorMessage = 'The value for parameter @FragmentationMedium_LOB is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @FragmentationMedium_NonLOB NOT IN(SELECT [Action] FROM @Actions WHERE [Action] <> 'INDEX_REBUILD_ONLINE' OR SERVERPROPERTY('EngineEdition') = 3)
  BEGIN
    SET @ErrorMessage = 'The value for parameter @FragmentationMedium_NonLOB is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @FragmentationLow_LOB NOT IN(SELECT [Action] FROM @Actions WHERE [Action] <> 'INDEX_REBUILD_ONLINE')
  BEGIN
    SET @ErrorMessage = 'The value for parameter @FragmentationLow_LOB is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @FragmentationLow_NonLOB NOT IN(SELECT [Action] FROM @Actions WHERE [Action] <> 'INDEX_REBUILD_ONLINE' OR SERVERPROPERTY('EngineEdition') = 3)
  BEGIN
    SET @ErrorMessage = 'The value for parameter @FragmentationLow_NonLOB is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF 'INDEX_REBUILD_ONLINE' IN(@FragmentationHigh_NonLOB, @FragmentationMedium_NonLOB, @FragmentationLow_NonLOB) AND SERVERPROPERTY('EngineEdition') <> 3
  BEGIN
    SET @ErrorMessage = 'Online rebuild is only supported in Enterprise and Developer Edition.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF 'INDEX_REBUILD_ONLINE' IN(@FragmentationHigh_LOB, @FragmentationMedium_LOB, @FragmentationLow_LOB)
  BEGIN
    SET @ErrorMessage = 'Online rebuild is only supported on indexes with no LOB columns.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @FragmentationLevel1 <= 0 OR @FragmentationLevel1 >= 100 OR @FragmentationLevel1 >= @FragmentationLevel2 OR @FragmentationLevel1 IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @FragmentationLevel1 is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @FragmentationLevel2 <= 0 OR @FragmentationLevel2 >= 100 OR @FragmentationLevel2 <= @FragmentationLevel1 OR @FragmentationLevel2 IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @FragmentationLevel2 is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @PageCountLevel < 0 OR @PageCountLevel IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @PageCountLevel is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @SortInTempdb NOT IN('Y','N') OR @SortInTempdb IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @SortInTempdb is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @MaxDOP < 0 OR @MaxDOP > 64 OR @MaxDOP > (SELECT cpu_count FROM sys.dm_os_sys_info) OR (@MaxDOP > 1 AND SERVERPROPERTY('EngineEdition') <> 3)
  BEGIN
    SET @ErrorMessage = 'The value for parameter @MaxDOP is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @MaxDOP > 1 AND SERVERPROPERTY('EngineEdition') <> 3
  BEGIN
    SET @ErrorMessage = 'Parallel index operations are only supported in Enterprise and Developer Edition.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @FillFactor <= 0 OR @FillFactor > 100
  BEGIN
    SET @ErrorMessage = 'The value for parameter @FillFactor is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @LOBCompaction NOT IN('Y','N') OR @LOBCompaction IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @LOBCompaction is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @StatisticsSample <= 0 OR @StatisticsSample  > 100
  OR (@StatisticsSample IS NOT NULL AND 'INDEX_REORGANIZE_STATISTICS_UPDATE' NOT IN(@FragmentationHigh_LOB, @FragmentationHigh_NonLOB, @FragmentationMedium_LOB, @FragmentationMedium_NonLOB, @FragmentationLow_LOB, @FragmentationLow_NonLOB) AND 'STATISTICS_UPDATE' NOT IN(@FragmentationHigh_LOB, @FragmentationHigh_NonLOB, @FragmentationMedium_LOB, @FragmentationMedium_NonLOB, @FragmentationLow_LOB, @FragmentationLow_NonLOB))
  BEGIN
    SET @ErrorMessage = 'The value for parameter @StatisticsSample is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @PartitionLevel NOT IN('Y','N') OR @PartitionLevel IS NULL OR (@PartitionLevel = 'Y' AND SERVERPROPERTY('EngineEdition') <> 3)
  BEGIN
    SET @ErrorMessage = 'The value for parameter @PartitionLevel is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @PartitionLevel = 'Y' AND SERVERPROPERTY('EngineEdition') <> 3
  BEGIN
    SET @ErrorMessage = 'Table partitioning is only supported in Enterprise and Developer Edition.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @TimeLimit < 0
  BEGIN
    SET @ErrorMessage = 'The value for parameter @TimeLimit is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  IF @Execute NOT IN('Y','N') OR @Execute IS NULL
  BEGIN
    SET @ErrorMessage = 'The value for parameter @Execute is not supported.' + CHAR(13) + CHAR(10)
    RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
    SET @Error = @@ERROR
  END

  ----------------------------------------------------------------------------------------------------
  --// Check error variable                                                                       //--
  ----------------------------------------------------------------------------------------------------

  IF @Error <> 0 GOTO Logging

  ----------------------------------------------------------------------------------------------------
  --// Execute commands                                                                           //--
  ----------------------------------------------------------------------------------------------------

  WHILE EXISTS (SELECT * FROM @tmpDatabases WHERE Completed = 0)
  BEGIN

    SELECT TOP 1 @CurrentID = ID,
                 @CurrentDatabase = DatabaseName
    FROM @tmpDatabases
    WHERE Completed = 0
    ORDER BY ID ASC

    -- Set database message
    SET @DatabaseMessage = 'DateTime: ' + CONVERT(nvarchar,GETDATE(),120) + CHAR(13) + CHAR(10)
    SET @DatabaseMessage = @DatabaseMessage + 'Database: ' + QUOTENAME(@CurrentDatabase) + CHAR(13) + CHAR(10)
    SET @DatabaseMessage = @DatabaseMessage + 'Status: ' + CAST(DATABASEPROPERTYEX(@CurrentDatabase,'status') AS nvarchar) + CHAR(13) + CHAR(10)
    SET @DatabaseMessage = @DatabaseMessage + 'Updateability: ' + CAST(DATABASEPROPERTYEX(@CurrentDatabase,'updateability') AS nvarchar) + CHAR(13) + CHAR(10)
    SET @DatabaseMessage = REPLACE(@DatabaseMessage,'%','%%')
    RAISERROR(@DatabaseMessage,10,1) WITH NOWAIT

    IF DATABASEPROPERTYEX(@CurrentDatabase,'status') = 'ONLINE' AND DATABASEPROPERTYEX(@CurrentDatabase,'updateability') = 'READ_WRITE'
    BEGIN

      -- Select indexes in the current database
      IF @PartitionLevel = 'N' SET @CurrentCommandSelect01 = 'SELECT ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas.[schema_id], ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas.[name], ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[object_id], ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[name], RTRIM(' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[type]), ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.index_id, ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[name], ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[type], NULL AS partition_id, NULL AS partition_number, NULL AS partition_count, 0 AS completed FROM ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes INNER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.objects ON ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[object_id] = ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[object_id] INNER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas ON ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[schema_id] = ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas.[schema_id] WHERE ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[type] IN(''U'',''V'') AND ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.is_ms_shipped = 0 AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[type] IN(1,2,3,4) AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.is_disabled = 0 AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.is_hypothetical = 0 ORDER BY ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas.[schema_id] ASC, ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[object_id] ASC, ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.index_id ASC'
      IF @PartitionLevel = 'Y' SET @CurrentCommandSelect01 = 'SELECT ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas.[schema_id], ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas.[name], ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[object_id], ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[name], RTRIM(' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[type]), ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.index_id, ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[name], ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[type], ' + QUOTENAME(@CurrentDatabase) + '.sys.partitions.partition_id, ' + QUOTENAME(@CurrentDatabase) + '.sys.partitions.partition_number, IndexPartitions.partition_count, 0 AS completed FROM ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes INNER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.objects ON ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[object_id] = ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[object_id] INNER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas ON ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[schema_id] = ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas.[schema_id] LEFT OUTER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.partitions ON ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[object_id] = ' + QUOTENAME(@CurrentDatabase) + '.sys.partitions.[object_id] AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.index_id = ' + QUOTENAME(@CurrentDatabase) + '.sys.partitions.index_id LEFT OUTER JOIN (SELECT [object_id], index_id, COUNT(*) AS partition_count FROM ' + QUOTENAME(@CurrentDatabase) + '.sys.partitions GROUP BY [object_id], index_id) IndexPartitions ON ' + QUOTENAME(@CurrentDatabase) + '.sys.partitions.[object_id] = IndexPartitions.[object_id] AND ' + QUOTENAME(@CurrentDatabase) + '.sys.partitions.[index_id] = IndexPartitions.[index_id] WHERE ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[type] IN(''U'',''V'') AND ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.is_ms_shipped = 0 AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[type] IN(1,2,3,4) AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.is_disabled = 0 AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.is_hypothetical = 0 ORDER BY ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas.[schema_id] ASC, ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[object_id] ASC, ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.index_id ASC, ' + QUOTENAME(@CurrentDatabase) + '.sys.partitions.partition_number ASC'

      INSERT INTO @tmpIndexes (SchemaID, SchemaName, ObjectID, ObjectName, ObjectType, IndexID, IndexName, IndexType, PartitionID, PartitionNumber, PartitionCount, Completed)
      EXECUTE(@CurrentCommandSelect01)

      WHILE EXISTS (SELECT * FROM @tmpIndexes WHERE Completed = 0)
      BEGIN

        SELECT TOP 1 @CurrentIxID = IxID,
                     @CurrentSchemaID = SchemaID,
                     @CurrentSchemaName = SchemaName,
                     @CurrentObjectID = ObjectID,
                     @CurrentObjectName = ObjectName,
                     @CurrentObjectType = ObjectType,
                     @CurrentIndexID = IndexID,
                     @CurrentIndexName = IndexName,
                     @CurrentIndexType = IndexType,
                     @CurrentPartitionID = PartitionID,
                     @CurrentPartitionNumber = PartitionNumber,
                     @CurrentPartitionCount = PartitionCount
        FROM @tmpIndexes
        WHERE Completed = 0
        ORDER BY IxID ASC

        -- Is the index a partition?
        IF @CurrentPartitionNumber IS NULL OR @CurrentPartitionCount = 1 BEGIN SET @CurrentIsPartition = 0 END ELSE BEGIN SET @CurrentIsPartition = 1 END

        -- Does the index exist?
        IF @CurrentIsPartition = 0 SET @CurrentCommandSelect02 = 'SELECT COUNT(*) FROM ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes INNER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.objects ON ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[object_id] = ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[object_id] INNER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas ON ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[schema_id] = ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas.[schema_id] WHERE ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[type] IN(''U'',''V'') AND ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.is_ms_shipped = 0 AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[type] IN(1,2,3,4) AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.is_disabled = 0 AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.is_hypothetical = 0 AND ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas.[schema_id] = ' + CAST(@CurrentSchemaID AS nvarchar) + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas.[name] = N' + QUOTENAME(@CurrentSchemaName,'''') + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[object_id] = ' + CAST(@CurrentObjectID AS nvarchar) + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[name] = N' + QUOTENAME(@CurrentObjectName,'''') + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[type] = N' + QUOTENAME(@CurrentObjectType,'''') + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.index_id = ' + CAST(@CurrentIndexID AS nvarchar) + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[name] = N' + QUOTENAME(@CurrentIndexName,'''') + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[type] = ' + CAST(@CurrentIndexType AS nvarchar)
        IF @CurrentIsPartition = 1 SET @CurrentCommandSelect02 = 'SELECT COUNT(*) FROM ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes INNER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.objects ON ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[object_id] = ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[object_id] INNER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas ON ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[schema_id] = ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas.[schema_id] INNER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.partitions ON ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[object_id] = ' + QUOTENAME(@CurrentDatabase) + '.sys.partitions.[object_id] AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.index_id = ' + QUOTENAME(@CurrentDatabase) + '.sys.partitions.index_id WHERE ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[type] IN(''U'',''V'') AND ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.is_ms_shipped = 0 AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[type] IN(1,2,3,4) AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.is_disabled = 0 AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.is_hypothetical = 0 AND ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas.[schema_id] = ' + CAST(@CurrentSchemaID AS nvarchar) + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.schemas.[name] = N' + QUOTENAME(@CurrentSchemaName,'''') + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[object_id] = ' + CAST(@CurrentObjectID AS nvarchar) + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[name] = N' + QUOTENAME(@CurrentObjectName,'''') + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.objects.[type] = N' + QUOTENAME(@CurrentObjectType,'''') + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.index_id = ' + CAST(@CurrentIndexID AS nvarchar) + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[name] = N' + QUOTENAME(@CurrentIndexName,'''') + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[type] = ' + CAST(@CurrentIndexType AS nvarchar) + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.partitions.partition_id = ' + CAST(@CurrentPartitionID AS nvarchar) + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.partitions.partition_number = ' + CAST(@CurrentPartitionNumber AS nvarchar)

        INSERT INTO @tmpIndexExists ([Count])
        EXECUTE(@CurrentCommandSelect02)

        IF (SELECT [Count] FROM @tmpIndexExists) > 0 BEGIN SET @CurrentIndexExists = 1 END ELSE BEGIN SET @CurrentIndexExists = 0 END

        IF @CurrentIndexExists = 0 GOTO NoAction

        -- Does the index contain a LOB?
        IF @CurrentIndexType = 1 SET @CurrentCommandSelect03 = 'SELECT COUNT(*) FROM ' + QUOTENAME(@CurrentDatabase) + '.sys.columns INNER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.types ON ' + QUOTENAME(@CurrentDatabase) + '.sys.columns.system_type_id = ' + QUOTENAME(@CurrentDatabase) + '.sys.types.user_type_id OR (' + QUOTENAME(@CurrentDatabase) + '.sys.columns.user_type_id = ' + QUOTENAME(@CurrentDatabase) + '.sys.types.user_type_id AND '+ QUOTENAME(@CurrentDatabase) + '.sys.types.is_assembly_type = 1) WHERE ' + QUOTENAME(@CurrentDatabase) + '.sys.columns.[object_id] = ' + CAST(@CurrentObjectID AS nvarchar) + ' AND (' + QUOTENAME(@CurrentDatabase) + '.sys.types.name IN(''xml'',''image'',''text'',''ntext'') OR (' + QUOTENAME(@CurrentDatabase) + '.sys.types.name IN(''varchar'',''nvarchar'',''varbinary'') AND ' + QUOTENAME(@CurrentDatabase) + '.sys.columns.max_length = -1) OR (' + QUOTENAME(@CurrentDatabase) + '.sys.types.is_assembly_type = 1 AND ' + QUOTENAME(@CurrentDatabase) + '.sys.columns.max_length = -1))'
        IF @CurrentIndexType = 2 SET @CurrentCommandSelect03 = 'SELECT COUNT(*) FROM ' + QUOTENAME(@CurrentDatabase) + '.sys.index_columns INNER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.columns ON ' + QUOTENAME(@CurrentDatabase) + '.sys.index_columns.[object_id] = ' + QUOTENAME(@CurrentDatabase) + '.sys.columns.[object_id] AND ' + QUOTENAME(@CurrentDatabase) + '.sys.index_columns.column_id = ' + QUOTENAME(@CurrentDatabase) + '.sys.columns.column_id INNER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.types ON ' + QUOTENAME(@CurrentDatabase) + '.sys.columns.system_type_id = ' + QUOTENAME(@CurrentDatabase) + '.sys.types.user_type_id OR (' + QUOTENAME(@CurrentDatabase) + '.sys.columns.user_type_id = ' + QUOTENAME(@CurrentDatabase) + '.sys.types.user_type_id AND ' + QUOTENAME(@CurrentDatabase) + '.sys.types.is_assembly_type = 1) WHERE ' + QUOTENAME(@CurrentDatabase) + '.sys.index_columns.[object_id] = ' + CAST(@CurrentObjectID AS nvarchar) + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.index_columns.index_id = ' + CAST(@CurrentIndexID AS nvarchar) + ' AND (' + QUOTENAME(@CurrentDatabase) + '.sys.types.[name] IN(''xml'',''image'',''text'',''ntext'') OR (' + QUOTENAME(@CurrentDatabase) + '.sys.types.[name] IN(''varchar'',''nvarchar'',''varbinary'') AND ' + QUOTENAME(@CurrentDatabase) + '.sys.columns.max_length = -1) OR (' + QUOTENAME(@CurrentDatabase) + '.sys.types.is_assembly_type = 1 AND ' + QUOTENAME(@CurrentDatabase) + '.sys.columns.max_length = -1))'
        IF @CurrentIndexType = 3 SET @CurrentCommandSelect03 = 'SELECT 1'
        IF @CurrentIndexType = 4 SET @CurrentCommandSelect03 = 'SELECT 1'

        INSERT INTO @tmpIsLOB ([Count])
        EXECUTE(@CurrentCommandSelect03)

        IF (SELECT [Count] FROM @tmpIsLOB) > 0 BEGIN SET @CurrentIsLOB = 1 END ELSE BEGIN SET @CurrentIsLOB = 0 END

        -- Is Allow_Page_Locks set to On?
        SET @CurrentCommandSelect04 = 'SELECT COUNT(*) FROM ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes WHERE ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[object_id] = ' + CAST(@CurrentObjectID AS nvarchar) + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[index_id] = ' + CAST(@CurrentIndexID AS nvarchar) + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[allow_page_locks] = 1'

        INSERT INTO @tmpAllowPageLocks ([Count])
        EXECUTE(@CurrentCommandSelect04)

        IF (SELECT [Count] FROM @tmpAllowPageLocks) > 0 BEGIN SET @CurrentAllowPageLocks = 1 END ELSE BEGIN SET @CurrentAllowPageLocks = 0 END

        -- Is the index on a read-only filegroup?
        SET @CurrentCommandSelect05 = 'SELECT COUNT(*) FROM (SELECT ' + QUOTENAME(@CurrentDatabase) + '.sys.filegroups.data_space_id FROM ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes INNER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.destination_data_spaces ON ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.data_space_id = ' + QUOTENAME(@CurrentDatabase) + '.sys.destination_data_spaces.partition_scheme_id INNER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.filegroups ON ' + QUOTENAME(@CurrentDatabase) + '.sys.destination_data_spaces.data_space_id = ' + QUOTENAME(@CurrentDatabase) + '.sys.filegroups.data_space_id WHERE ' + QUOTENAME(@CurrentDatabase) + '.sys.filegroups.is_read_only = 1 AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[object_id] = ' + CAST(@CurrentObjectID AS nvarchar) + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[index_id] = ' + CAST(@CurrentIndexID AS nvarchar)
        IF @CurrentIsPartition = 1 SET @CurrentCommandSelect05 = @CurrentCommandSelect05 + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.destination_data_spaces.destination_id = ' + CAST(@CurrentPartitionNumber AS nvarchar)
        SET @CurrentCommandSelect05 = @CurrentCommandSelect05 + ' UNION SELECT ' + QUOTENAME(@CurrentDatabase) + '.sys.filegroups.data_space_id FROM ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes INNER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.filegroups ON ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.data_space_id = ' + QUOTENAME(@CurrentDatabase) + '.sys.filegroups.data_space_id WHERE ' + QUOTENAME(@CurrentDatabase) + '.sys.filegroups.is_read_only = 1 AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[object_id] = ' + CAST(@CurrentObjectID AS nvarchar) + ' AND ' + QUOTENAME(@CurrentDatabase) + '.sys.indexes.[index_id] = ' + CAST(@CurrentIndexID AS nvarchar)
        IF @CurrentIndexType = 1 SET @CurrentCommandSelect05 = @CurrentCommandSelect05 + ' UNION SELECT ' + QUOTENAME(@CurrentDatabase) + '.sys.filegroups.data_space_id FROM ' + QUOTENAME(@CurrentDatabase) + '.sys.tables INNER JOIN ' + QUOTENAME(@CurrentDatabase) + '.sys.filegroups ON ' + QUOTENAME(@CurrentDatabase) + '.sys.tables.lob_data_space_id = ' + QUOTENAME(@CurrentDatabase) + '.sys.filegroups.data_space_id WHERE ' + QUOTENAME(@CurrentDatabase) + '.sys.filegroups.is_read_only = 1 AND ' + QUOTENAME(@CurrentDatabase) + '.sys.tables.[object_id] = ' + CAST(@CurrentObjectID AS nvarchar)
        SET @CurrentCommandSelect05 = @CurrentCommandSelect05 + ') ReadOnlyFileGroups'

        INSERT INTO @tmpOnReadOnlyFileGroup ([Count])
        EXECUTE(@CurrentCommandSelect05)

        IF (SELECT [Count] FROM @tmpOnReadOnlyFileGroup) > 0 BEGIN SET @CurrentOnReadOnlyFileGroup = 1 END ELSE BEGIN SET @CurrentOnReadOnlyFileGroup = 0 END

        -- Is the index fragmented?
        SELECT @CurrentFragmentationLevel = MAX(avg_fragmentation_in_percent),
               @CurrentPageCount = SUM(page_count)
        FROM sys.dm_db_index_physical_stats(DB_ID(@CurrentDatabase), @CurrentObjectID, @CurrentIndexID, @CurrentPartitionNumber, 'LIMITED')
        WHERE alloc_unit_type_desc = 'IN_ROW_DATA'
        AND index_level = 0
        SET @Error = @@ERROR
        IF @Error = 1222
        BEGIN
          SET @ErrorMessage = 'The object sys.dm_db_index_physical_stats is locked for the index ' + QUOTENAME(@CurrentSchemaName) + '.' + QUOTENAME(@CurrentObjectName) + '.' + QUOTENAME(@CurrentIndexName) + '.' + CHAR(13) + CHAR(10)
          SET @ErrorMessage = REPLACE(@ErrorMessage,'%','%%')
          RAISERROR(@ErrorMessage,16,1) WITH NOWAIT
          GOTO NoAction
        END

        -- Decide action
        SELECT @CurrentAction = CASE
        WHEN (@CurrentIsLOB = 1 OR @CurrentIsPartition = 1) AND @CurrentFragmentationLevel >= @FragmentationLevel2 AND @CurrentPageCount >= @PageCountLevel THEN @FragmentationHigh_LOB
        WHEN (@CurrentIsLOB = 0 AND @CurrentIsPartition = 0) AND @CurrentFragmentationLevel >= @FragmentationLevel2 AND @CurrentPageCount >= @PageCountLevel THEN @FragmentationHigh_NonLOB
        WHEN (@CurrentIsLOB = 1 OR @CurrentIsPartition = 1) AND @CurrentFragmentationLevel >= @FragmentationLevel1 AND @CurrentFragmentationLevel < @FragmentationLevel2 AND @CurrentPageCount >= @PageCountLevel THEN @FragmentationMedium_LOB
        WHEN (@CurrentIsLOB = 0 AND @CurrentIsPartition = 0) AND @CurrentFragmentationLevel >= @FragmentationLevel1 AND @CurrentFragmentationLevel < @FragmentationLevel2 AND @CurrentPageCount >= @PageCountLevel THEN @FragmentationMedium_NonLOB
        WHEN (@CurrentIsLOB = 1 OR @CurrentIsPartition = 1) AND (@CurrentFragmentationLevel < @FragmentationLevel1 OR @CurrentPageCount < @PageCountLevel) THEN @FragmentationLow_LOB
        WHEN (@CurrentIsLOB = 0 AND @CurrentIsPartition = 0) AND (@CurrentFragmentationLevel < @FragmentationLevel1 OR @CurrentPageCount < @PageCountLevel) THEN @FragmentationLow_NonLOB
        END

        -- Reorganizing an index is only allowed if Allow_Page_Locks is set to On
        IF @CurrentAction IN('INDEX_REORGANIZE','INDEX_REORGANIZE_STATISTICS_UPDATE') AND @CurrentAllowPageLocks = 0
        BEGIN
          SELECT @CurrentAction = CASE
          WHEN (@CurrentIsLOB = 0 AND @CurrentIsPartition = 0) AND 'INDEX_REBUILD_ONLINE' IN(@FragmentationHigh_NonLOB, @FragmentationMedium_NonLOB, @FragmentationLow_NonLOB) THEN 'INDEX_REBUILD_ONLINE'
          WHEN (@CurrentIsLOB = 0 AND @CurrentIsPartition = 0) AND 'INDEX_REBUILD_OFFLINE' IN(@FragmentationHigh_NonLOB, @FragmentationMedium_NonLOB, @FragmentationLow_NonLOB) THEN 'INDEX_REBUILD_OFFLINE'
          WHEN (@CurrentIsLOB = 1 OR @CurrentIsPartition = 1) AND 'INDEX_REBUILD_OFFLINE' IN(@FragmentationHigh_LOB, @FragmentationMedium_LOB, @FragmentationLow_LOB) THEN 'INDEX_REBUILD_OFFLINE'
          ELSE 'NOTHING'
          END
        END

        -- Create comment
        SET @CurrentComment = 'ObjectType: ' + CASE WHEN @CurrentObjectType = 'U' THEN 'Table' WHEN @CurrentObjectType = 'V' THEN 'View' ELSE 'N/A' END + ', '
        SET @CurrentComment = @CurrentComment + 'IndexType: ' + CASE WHEN @CurrentIndexType = 1 THEN 'Clustered' WHEN @CurrentIndexType = 2 THEN 'NonClustered' WHEN @CurrentIndexType = 3 THEN 'XML' WHEN @CurrentIndexType = 4 THEN 'Spatial' ELSE 'N/A' END + ', '
        SET @CurrentComment = @CurrentComment + 'LOB: ' + CASE WHEN @CurrentIsLOB = 1 THEN 'Yes' WHEN @CurrentIsLOB = 0 THEN 'No' ELSE 'N/A' END + ', '
        SET @CurrentComment = @CurrentComment + 'AllowPageLocks: ' + CASE WHEN @CurrentAllowPageLocks = 1 THEN 'Yes' WHEN @CurrentAllowPageLocks = 0 THEN 'No' ELSE 'N/A' END + ', '
        SET @CurrentComment = @CurrentComment + 'PageCount: ' + CAST(@CurrentPageCount AS nvarchar) + ', '
        SET @CurrentComment = @CurrentComment + 'Fragmentation: ' + CAST(@CurrentFragmentationLevel AS nvarchar)

        -- Check time limit
        IF GETDATE() >= DATEADD(ss,@TimeLimit,@StartTime)
        BEGIN
          SET @Execute = 'N'
        END

        IF @CurrentAction IN('INDEX_REBUILD_ONLINE','INDEX_REBUILD_OFFLINE','INDEX_REORGANIZE','INDEX_REORGANIZE_STATISTICS_UPDATE') AND @CurrentOnReadOnlyFileGroup = 0
        BEGIN
          SET @CurrentCommand01 = 'ALTER INDEX ' + QUOTENAME(@CurrentIndexName) + ' ON ' + QUOTENAME(@CurrentDatabase) + '.' + QUOTENAME(@CurrentSchemaName) + '.' + QUOTENAME(@CurrentObjectName)

          IF @CurrentAction IN('INDEX_REBUILD_ONLINE','INDEX_REBUILD_OFFLINE')
          BEGIN
            SET @CurrentCommand01 = @CurrentCommand01 + ' REBUILD'
            IF @CurrentIsPartition = 1 SET @CurrentCommand01 = @CurrentCommand01 + ' PARTITION = ' + CAST(@CurrentPartitionNumber AS nvarchar)
            SET @CurrentCommand01 = @CurrentCommand01 + ' WITH ('
            IF @SortInTempdb = 'Y' SET @CurrentCommand01 = @CurrentCommand01 + 'SORT_IN_TEMPDB = ON'
            IF @SortInTempdb = 'N' SET @CurrentCommand01 = @CurrentCommand01 + 'SORT_IN_TEMPDB = OFF'
            IF @CurrentAction = 'INDEX_REBUILD_ONLINE' AND @CurrentIsPartition = 0 SET @CurrentCommand01 = @CurrentCommand01 + ', ONLINE = ON'
            IF @CurrentAction = 'INDEX_REBUILD_OFFLINE' AND @CurrentIsPartition = 0 SET @CurrentCommand01 = @CurrentCommand01 + ', ONLINE = OFF'
            IF @MaxDOP IS NOT NULL SET @CurrentCommand01 = @CurrentCommand01 + ', MAXDOP = ' + CAST(@MaxDOP AS nvarchar)
            IF @FillFactor IS NOT NULL AND @CurrentIsPartition = 0 SET @CurrentCommand01 = @CurrentCommand01 + ', FILLFACTOR = ' + CAST(@FillFactor AS nvarchar)
            SET @CurrentCommand01 = @CurrentCommand01 + ')'
          END

          IF @CurrentAction IN('INDEX_REORGANIZE','INDEX_REORGANIZE_STATISTICS_UPDATE')
          BEGIN
            SET @CurrentCommand01 = @CurrentCommand01 + ' REORGANIZE'
            IF @CurrentIsPartition = 1 SET @CurrentCommand01 = @CurrentCommand01 + ' PARTITION = ' + CAST(@CurrentPartitionNumber AS nvarchar)
            SET @CurrentCommand01 = @CurrentCommand01 + ' WITH ('
            IF @LOBCompaction = 'Y' SET @CurrentCommand01 = @CurrentCommand01 + 'LOB_COMPACTION = ON'
            IF @LOBCompaction = 'N' SET @CurrentCommand01 = @CurrentCommand01 + 'LOB_COMPACTION = OFF'
            SET @CurrentCommand01 = @CurrentCommand01 + ')'
          END

          EXECUTE @CurrentCommandOutput01 = [dbo].[CommandExecute] @CurrentCommand01, @CurrentComment, 2, @Execute
          SET @Error = @@ERROR
          IF @Error <> 0 SET @CurrentCommandOutput01 = @Error
        END

        IF @CurrentAction IN('INDEX_REORGANIZE_STATISTICS_UPDATE','STATISTICS_UPDATE') AND @CurrentOnReadOnlyFileGroup = 0 AND @CurrentIndexType IN(1,2) AND @CurrentIsPartition = 0
        BEGIN
          SET @CurrentCommand02 = 'UPDATE STATISTICS ' + QUOTENAME(@CurrentDatabase) + '.' + QUOTENAME(@CurrentSchemaName) + '.' + QUOTENAME(@CurrentObjectName) + ' ' + QUOTENAME(@CurrentIndexName)
          IF @StatisticsSample = 100 SET @CurrentCommand02 = @CurrentCommand02 + ' WITH FULLSCAN'
          IF @StatisticsSample IS NOT NULL AND @StatisticsSample <> 100 SET @CurrentCommand02 = @CurrentCommand02 + ' WITH SAMPLE ' + CAST(@StatisticsSample AS nvarchar) + ' PERCENT'

          EXECUTE @CurrentCommandOutput02 = [dbo].[CommandExecute] @CurrentCommand02, '', 2, @Execute
          SET @Error = @@ERROR
          IF @Error <> 0 SET @CurrentCommandOutput02 = @Error
        END

        NoAction:

        -- Update that the index is completed
        UPDATE @tmpIndexes
        SET Completed = 1
        WHERE IxID = @CurrentIxID

        -- Clear variables
        SET @CurrentCommandSelect02 = NULL
        SET @CurrentCommandSelect03 = NULL
        SET @CurrentCommandSelect04 = NULL
        SET @CurrentCommandSelect05 = NULL

        SET @CurrentCommand01 = NULL
        SET @CurrentCommand02 = NULL

        SET @CurrentCommandOutput01 = NULL
        SET @CurrentCommandOutput02 = NULL

        SET @CurrentIxID = NULL
        SET @CurrentSchemaID = NULL
        SET @CurrentSchemaName = NULL
        SET @CurrentObjectID = NULL
        SET @CurrentObjectName = NULL
        SET @CurrentObjectType = NULL
        SET @CurrentIndexID = NULL
        SET @CurrentIndexName = NULL
        SET @CurrentIndexType = NULL
        SET @CurrentPartitionID = NULL
        SET @CurrentPartitionNumber = NULL
        SET @CurrentPartitionCount = NULL
        SET @CurrentIsPartition = NULL
        SET @CurrentIndexExists = NULL
        SET @CurrentIsLOB = NULL
        SET @CurrentAllowPageLocks = NULL
        SET @CurrentOnReadOnlyFileGroup = NULL
        SET @CurrentFragmentationLevel = NULL
        SET @CurrentPageCount = NULL
        SET @CurrentAction = NULL
        SET @CurrentComment = NULL

        DELETE FROM @tmpIndexExists
        DELETE FROM @tmpIsLOB
        DELETE FROM @tmpAllowPageLocks
        DELETE FROM @tmpOnReadOnlyFileGroup

      END

    END

    -- Update that the database is completed
    UPDATE @tmpDatabases
    SET Completed = 1
    WHERE ID = @CurrentID

    -- Clear variables
    SET @CurrentID = NULL
    SET @CurrentDatabase = NULL

    SET @CurrentCommandSelect01 = NULL

    DELETE FROM @tmpIndexes

  END

  ----------------------------------------------------------------------------------------------------
  --// Log completing information                                                                 //--
  ----------------------------------------------------------------------------------------------------

  Logging:
  SET @EndMessage = 'DateTime: ' + CONVERT(nvarchar,GETDATE(),120)
  SET @EndMessage = REPLACE(@EndMessage,'%','%%')
  RAISERROR(@EndMessage,10,1) WITH NOWAIT

  ----------------------------------------------------------------------------------------------------

END
GO

IF (SELECT CAST([Value] AS nvarchar) FROM #Config WHERE Name = 'Error') <> '0' OR (SELECT [Value] FROM #Config WHERE Name = 'Jobs') <> 'Y' OR SERVERPROPERTY('EngineEdition') = 4 OR CAST(LEFT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max)),CHARINDEX('.',CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max)))-1) + '.' + REPLACE(RIGHT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max)), LEN(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max))) - CHARINDEX('.',CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max)))),'.','') AS numeric(18,9)) < 9.002047
BEGIN
  RETURN
END

DECLARE @LogDirectory nvarchar(max)
DECLARE @BackupDirectory nvarchar(max)
DECLARE @Database nvarchar(max)
DECLARE @OutputFile nvarchar(max)

DECLARE @JobName01 nvarchar(max)
DECLARE @JobName02 nvarchar(max)
DECLARE @JobName03 nvarchar(max)
DECLARE @JobName04 nvarchar(max)
DECLARE @JobName05 nvarchar(max)
DECLARE @JobName06 nvarchar(max)
DECLARE @JobName07 nvarchar(max)

DECLARE @JobCommand01 nvarchar(max)
DECLARE @JobCommand02 nvarchar(max)
DECLARE @JobCommand03 nvarchar(max)
DECLARE @JobCommand04 nvarchar(max)
DECLARE @JobCommand05 nvarchar(max)
DECLARE @JobCommand06 nvarchar(max)
DECLARE @JobCommand07 nvarchar(max)

SELECT @LogDirectory = Value
FROM #Config
WHERE [Name] = 'LogDirectory'

SELECT @BackupDirectory = Value
FROM #Config
WHERE [Name] = 'BackupDirectory'

SELECT @Database = Value
FROM #Config
WHERE [Name] = 'Database'

SET @OutputFile = @LogDirectory + '\SQLAGENT_JOB_$(ESCAPE_SQUOTE(JOBID))_$(ESCAPE_SQUOTE(STEPID))_$(ESCAPE_SQUOTE(STRTDT))_$(ESCAPE_SQUOTE(STRTTM)).txt'

SET @JobName01 = 'DatabaseBackup - SYSTEM_DATABASES - FULL'
SET @JobCommand01 = 'sqlcmd -E -S $(ESCAPE_SQUOTE(SRVR)) -d ' + @Database + ' -Q "EXECUTE [dbo].[DatabaseBackup] @Databases = ''SYSTEM_DATABASES'', @Directory = ' + ISNULL('N''' + REPLACE(@BackupDirectory,'''','''''') + '''','NULL') + ', @BackupType = ''FULL'', @Verify = ''Y'', @CleanupTime = 24" -b'

SET @JobName02 = 'DatabaseBackup - USER_DATABASES - DIFF'
SET @JobCommand02 = 'sqlcmd -E -S $(ESCAPE_SQUOTE(SRVR)) -d ' + @Database + ' -Q "EXECUTE [dbo].[DatabaseBackup] @Databases = ''USER_DATABASES'', @Directory = ' + ISNULL('N''' + REPLACE(@BackupDirectory,'''','''''') + '''','NULL') + ', @BackupType = ''DIFF'', @Verify = ''Y'', @CleanupTime = 24" -b'

SET @JobName03 = 'DatabaseBackup - USER_DATABASES - FULL'
SET @JobCommand03 = 'sqlcmd -E -S $(ESCAPE_SQUOTE(SRVR)) -d ' + @Database + ' -Q "EXECUTE [dbo].[DatabaseBackup] @Databases = ''USER_DATABASES'', @Directory = ' + ISNULL('N''' + REPLACE(@BackupDirectory,'''','''''') + '''','NULL') + ', @BackupType = ''FULL'', @Verify = ''Y'', @CleanupTime = 24" -b'

SET @JobName04 = 'DatabaseBackup - USER_DATABASES - LOG'
SET @JobCommand04 = 'sqlcmd -E -S $(ESCAPE_SQUOTE(SRVR)) -d ' + @Database + ' -Q "EXECUTE [dbo].[DatabaseBackup] @Databases = ''USER_DATABASES'', @Directory = ' + ISNULL('N''' + REPLACE(@BackupDirectory,'''','''''') + '''','NULL') + ', @BackupType = ''LOG'', @Verify = ''Y'', @CleanupTime = 24" -b'

SET @JobName05 = 'DatabaseIntegrityCheck - SYSTEM_DATABASES'
SET @JobCommand05 = 'sqlcmd -E -S $(ESCAPE_SQUOTE(SRVR)) -d ' + @Database + ' -Q "EXECUTE [dbo].[DatabaseIntegrityCheck] @Databases = ''SYSTEM_DATABASES''" -b'

SET @JobName06 = 'DatabaseIntegrityCheck - USER_DATABASES'
SET @JobCommand06 = 'sqlcmd -E -S $(ESCAPE_SQUOTE(SRVR)) -d ' + @Database + ' -Q "EXECUTE [dbo].[DatabaseIntegrityCheck] @Databases = ''USER_DATABASES''" -b'

SET @JobName07 = 'IndexOptimize - USER_DATABASES'
IF SERVERPROPERTY('EngineEdition') = 3
BEGIN
  SET @JobCommand07 = 'sqlcmd -E -S $(ESCAPE_SQUOTE(SRVR)) -d ' + @Database + ' -Q "EXECUTE [dbo].[IndexOptimize] @Databases = ''USER_DATABASES'', @FragmentationHigh_NonLOB = ''INDEX_REBUILD_ONLINE''" -b'
END
ELSE
BEGIN
  SET @JobCommand07 = 'sqlcmd -E -S $(ESCAPE_SQUOTE(SRVR)) -d ' + @Database + ' -Q "EXECUTE [dbo].[IndexOptimize] @Databases = ''USER_DATABASES''" -b'
END

IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobs WHERE [name] = @JobName01)
BEGIN
  EXECUTE msdb.dbo.sp_add_job @job_name = @JobName01
  EXECUTE msdb.dbo.sp_add_jobstep @job_name = @JobName01, @step_name = @JobName01, @subsystem = 'CMDEXEC', @command = @JobCommand01, @output_file_name = @OutputFile
  EXECUTE msdb.dbo.sp_add_jobserver @job_name = @JobName01
END

IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobs WHERE [name] = @JobName02)
BEGIN
  EXECUTE msdb.dbo.sp_add_job @job_name = @JobName02
  EXECUTE msdb.dbo.sp_add_jobstep @job_name = @JobName02, @step_name = @JobName02, @subsystem = 'CMDEXEC', @command = @JobCommand02, @output_file_name = @OutputFile
  EXECUTE msdb.dbo.sp_add_jobserver @job_name = @JobName02
END

IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobs WHERE [name] = @JobName03)
BEGIN
  EXECUTE msdb.dbo.sp_add_job @job_name = @JobName03
  EXECUTE msdb.dbo.sp_add_jobstep @job_name = @JobName03, @step_name = @JobName03, @subsystem = 'CMDEXEC', @command = @JobCommand03, @output_file_name = @OutputFile
  EXECUTE msdb.dbo.sp_add_jobserver @job_name = @JobName03
END

IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobs WHERE [name] = @JobName04)
BEGIN
  EXECUTE msdb.dbo.sp_add_job @job_name = @JobName04
  EXECUTE msdb.dbo.sp_add_jobstep @job_name = @JobName04, @step_name = @JobName04, @subsystem = 'CMDEXEC', @command = @JobCommand04, @output_file_name = @OutputFile
  EXECUTE msdb.dbo.sp_add_jobserver @job_name = @JobName04
END

IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobs WHERE [name] = @JobName05)
BEGIN
  EXECUTE msdb.dbo.sp_add_job @job_name = @JobName05
  EXECUTE msdb.dbo.sp_add_jobstep @job_name = @JobName05, @step_name = @JobName05, @subsystem = 'CMDEXEC', @command = @JobCommand05, @output_file_name = @OutputFile
  EXECUTE msdb.dbo.sp_add_jobserver @job_name = @JobName05
END

IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobs WHERE [name] = @JobName06)
BEGIN
  EXECUTE msdb.dbo.sp_add_job @job_name = @JobName06
  EXECUTE msdb.dbo.sp_add_jobstep @job_name = @JobName06, @step_name = @JobName06, @subsystem = 'CMDEXEC', @command = @JobCommand06, @output_file_name = @OutputFile
  EXECUTE msdb.dbo.sp_add_jobserver @job_name = @JobName06
END

IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobs WHERE [name] = @JobName07)
BEGIN
  EXECUTE msdb.dbo.sp_add_job @job_name = @JobName07
  EXECUTE msdb.dbo.sp_add_jobstep @job_name = @JobName07, @step_name = @JobName07, @subsystem = 'CMDEXEC', @command = @JobCommand07, @output_file_name = @OutputFile
  EXECUTE msdb.dbo.sp_add_jobserver @job_name = @JobName07
END
GO
