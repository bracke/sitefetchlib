with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;

with Http_Client.Cache;
with Http_Client.Clients;
with Http_Client.Crypto;
with Http_Client.Decompression;
with Http_Client.Errors;

with Sitefetch.URLs;

package body Sitefetch.Engine.Cache is
   use Ada.Strings.Unbounded;
   use Sitefetch.URLs;
   use type Ada.Directories.File_Kind;
   use type Ada.Directories.File_Size;
   use type Ada.Streams.Stream_Element_Offset;
   use type Http_Client.Errors.Result_Status;

   procedure Delete_Ordinary_File_If_Present (Path_Text : String) is
      Status : constant Http_Client.Errors.Result_Status :=
        Http_Client.Clients.Delete_Ordinary_File_If_Present (Path_Text);
      pragma Unreferenced (Status);
   begin
      null;
   end Delete_Ordinary_File_If_Present;

   procedure Write_Text
     (Path_Text    : String;
      Content_Text : String;
      Durability   : Write_Durability_Mode := Write_Durability_Default) is
      HTTP_Durability : constant Http_Client.Clients.File_Durability_Mode :=
        (case Durability is
            when Write_Durability_Default => Http_Client.Clients.File_Durability_Default,
            when Write_Durability_Flush_Temp_File => Http_Client.Clients.File_Durability_Flush_Temp_File,
            when Write_Durability_Sync_Data_And_Directory =>
              Http_Client.Clients.File_Durability_Sync_Data_And_Directory);
      Status : constant Http_Client.Errors.Result_Status :=
        Http_Client.Clients.Write_Text_File_Atomically
          (Path          => Path_Text,
           Content       => Content_Text,
           Temp_Suffix   => ".sitefetch_tmp",
           Backup_Suffix => ".sitefetch_old",
           Durability    => HTTP_Durability);
   begin
      if Status /= Http_Client.Errors.Ok then
         raise Ada.Directories.Use_Error;
      end if;
   end Write_Text;

   Cache_Metadata_Version : constant Natural := 2;

   function Cache_Natural_Image (Value : Natural) return String is
   begin
      return Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Left);
   end Cache_Natural_Image;

   function Cache_Metadata_Path (Target_Path : String) return String is
   begin
      return Target_Path & ".sitefetch_http_cache";
   end Cache_Metadata_Path;

   function Partial_Download_Path (Target_Path : String) return String is
   begin
      return Target_Path & ".sitefetch_part";
   end Partial_Download_Path;

   function Existing_File_Size (Path_Text : String) return Natural is
      Size : Ada.Directories.File_Size;
   begin
      if not Ada.Directories.Exists (Path_Text)
        or else Ada.Directories.Kind (Path_Text) /= Ada.Directories.Ordinary_File
      then
         return 0;
      end if;

      Size := Ada.Directories.Size (Path_Text);
      if Size > Ada.Directories.File_Size (Natural'Last) then
         return Natural'Last;
      else
         return Natural (Size);
      end if;
   exception
      when others =>
         return 0;
   end Existing_File_Size;

   function Has_Suffix (Item : String; Suffix : String) return Boolean is
   begin
      return Item'Length >= Suffix'Length
        and then Item (Item'Last - Suffix'Length + 1 .. Item'Last) = Suffix;
   end Has_Suffix;

   function Hex_Digit (Value : Natural) return Character is
   begin
      if Value < 10 then
         return Character'Val (Character'Pos ('0') + Value);
      else
         return Character'Val (Character'Pos ('a') + Value - 10);
      end if;
   end Hex_Digit;

   function Unsigned_64_Hex (Value : Interfaces.Unsigned_64) return String is
      use type Interfaces.Unsigned_64;

      Result    : String (1 .. 16);
      Remaining : Interfaces.Unsigned_64 := Value;
   begin
      for Index_Value in reverse Result'Range loop
         Result (Index_Value) := Hex_Digit (Natural (Remaining mod 16));
         Remaining := Remaining / 16;
      end loop;

      return Result;
   end Unsigned_64_Hex;

   function Cache_Hash_Algorithm_Name (Algorithm : Cache_Hash_Algorithm) return String is
   begin
      case Algorithm is
         when Cache_Hash_FNV1a_64 =>
            return "fnv1a-64";
         when Cache_Hash_SHA256 =>
            return "sha256";
         when Cache_Hash_None =>
            return "none";
      end case;
   end Cache_Hash_Algorithm_Name;

   function File_Content_Hash
     (Path_Text : String;
      Algorithm : Cache_Hash_Algorithm := Cache_Hash_FNV1a_64) return String is
      use type Ada.Streams.Stream_Element_Offset;
      use type Interfaces.Unsigned_64;

      File   : Ada.Streams.Stream_IO.File_Type;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 4_096);
      Last   : Ada.Streams.Stream_Element_Offset;
      Hash   : Interfaces.Unsigned_64 := 16#CBF29CE484222325#;
      Prime  : constant Interfaces.Unsigned_64 := 16#100000001B3#;
   begin
      if Algorithm = Cache_Hash_None then
         return "";
      elsif Algorithm = Cache_Hash_SHA256 then
         return Http_Client.Crypto.Digest_File_SHA256_Hex (Path_Text);
      end if;

      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path_Text);
      while not Ada.Streams.Stream_IO.End_Of_File (File) loop
         Ada.Streams.Stream_IO.Read (File, Buffer, Last);
         for Index_Value in Buffer'First .. Last loop
            Hash := (Hash xor Interfaces.Unsigned_64 (Buffer (Index_Value))) * Prime;
         end loop;
      end loop;
      Ada.Streams.Stream_IO.Close (File);
      return Unsigned_64_Hex (Hash);
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         return "";
   end File_Content_Hash;

   function Has_Cache_Token (Header_Text : String; Token : String) return Boolean is
   begin
      return Http_Client.Cache.Cache_Control_Has_Directive (Header_Text, Token);
   end Has_Cache_Token;

   function Resume_Validator (Metadata : Cache_Metadata) return Unbounded_String is
   begin
      return Http_Client.Clients.Resume_Validator
        (ETag          => To_String (Metadata.ETag),
         Last_Modified => To_String (Metadata.Last_Modified),
         ETag_Is_Weak  => Metadata.ETag_Is_Weak,
         Resume_Safe   => Metadata.Resume_Safe);
   end Resume_Validator;

   function Is_Weak_ETag (ETag : String) return Boolean is
   begin
      return Http_Client.Cache.Is_Weak_ETag (ETag);
   end Is_Weak_ETag;

   function Boolean_Image (Value : Boolean) return String is
   begin
      if Value then
         return "true";
      else
         return "false";
      end if;
   end Boolean_Image;

   function Metadata_Boolean (Text : String) return Boolean is
      Lower : Unbounded_String := Null_Unbounded_String;
   begin
      for Ch of Text loop
         Append (Lower, Ada.Characters.Handling.To_Lower (Ch));
      end loop;

      return To_String (Lower) in "true" | "yes" | "1";
   end Metadata_Boolean;

   function Natural_Metadata_Value (Text : String; Value : out Natural) return Boolean is
   begin
      if Text = "" then
         return False;
      end if;

      Value := 0;
      for Ch of Text loop
         if Ch not in '0' .. '9' then
            return False;
         elsif Value > (Natural'Last - Character'Pos (Ch) + Character'Pos ('0')) / 10 then
            return False;
         end if;

         Value := Value * 10 + Character'Pos (Ch) - Character'Pos ('0');
      end loop;

      return True;
   end Natural_Metadata_Value;

   function Metadata_Value (Line : String; Name : String) return String is
      Prefix : constant String := Name & ": ";
   begin
      if Starts_With (Line, Prefix) then
         return Line (Line'First + Prefix'Length .. Line'Last);
      else
         return "";
      end if;
   end Metadata_Value;

   function Trimmed (Text : String) return String is
   begin
      return Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both);
   end Trimmed;

   function Rejected_Cache_Metadata (Reason : String) return Cache_Metadata is
      Result : Cache_Metadata;
   begin
      Result.Rejection_Reason := To_Unbounded_String (Reason);
      return Result;
   end Rejected_Cache_Metadata;

   function Read_Cache_Metadata
     (Target_Path           : String;
      Verify_Local_Content : Boolean := True;
      Hash_Algorithm       : Cache_Hash_Algorithm := Cache_Hash_FNV1a_64) return Cache_Metadata is
      Path_Text : constant String := Cache_Metadata_Path (Target_Path);
      File      : Ada.Text_IO.File_Type;
      Result    : Cache_Metadata;
   begin
      if not Ada.Directories.Exists (Target_Path) then
         return Rejected_Cache_Metadata ("local file missing");
      elsif not Ada.Directories.Exists (Path_Text) then
         return Rejected_Cache_Metadata ("cache sidecar missing");
      end if;

      begin
         Result.Sidecar_Time := Ada.Directories.Modification_Time (Path_Text);
         Result.Sidecar_Time_Known := True;
      exception
         when others =>
            null;
      end;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path_Text);
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
         begin
            if Starts_With (Line, "Cache-Version: ") then
               declare
                  Parsed : Natural := 0;
               begin
                  if Natural_Metadata_Value (Metadata_Value (Line, "Cache-Version"), Parsed) then
                     Result.Cache_Version := Parsed;
                     Result.Cache_Version_Known := True;
                  end if;
               end;
            elsif Starts_With (Line, "URL: ") then
               Result.URL := To_Unbounded_String (Metadata_Value (Line, "URL"));
            elsif Starts_With (Line, "Final-URL: ") then
               Result.Final_URL := To_Unbounded_String (Metadata_Value (Line, "Final-URL"));
            elsif Starts_With (Line, "Content-Type: ") then
               Result.Content_Type := To_Unbounded_String (Metadata_Value (Line, "Content-Type"));
            elsif Starts_With (Line, "Content-Length: ") then
               declare
                  Parsed : Natural := 0;
               begin
                  if Natural_Metadata_Value (Metadata_Value (Line, "Content-Length"), Parsed) then
                     Result.Content_Length := Parsed;
                     Result.Has_Content_Length := True;
                  end if;
               end;
            elsif Starts_With (Line, "ETag: ") then
               Result.ETag := To_Unbounded_String (Metadata_Value (Line, "ETag"));
            elsif Starts_With (Line, "ETag-Weak: ") then
               Result.ETag_Is_Weak := Metadata_Boolean (Metadata_Value (Line, "ETag-Weak"));
            elsif Starts_With (Line, "Last-Modified: ") then
               Result.Last_Modified := To_Unbounded_String (Metadata_Value (Line, "Last-Modified"));
            elsif Starts_With (Line, "Cache-Control: ") then
               Result.Cache_Control := To_Unbounded_String (Metadata_Value (Line, "Cache-Control"));
            elsif Starts_With (Line, "Expires: ") then
               Result.Expires := To_Unbounded_String (Metadata_Value (Line, "Expires"));
            elsif Starts_With (Line, "Vary: ") then
               Result.Vary := To_Unbounded_String (Metadata_Value (Line, "Vary"));
            elsif Starts_With (Line, "Request-User-Agent: ") then
               Result.Request_User_Agent := To_Unbounded_String (Metadata_Value (Line, "Request-User-Agent"));
            elsif Starts_With (Line, "Request-Accept-Language: ") then
               Result.Request_Accept_Language := To_Unbounded_String
                 (Metadata_Value (Line, "Request-Accept-Language"));
            elsif Starts_With (Line, "Request-Accept-Encoding: ") then
               Result.Request_Accept_Encoding := To_Unbounded_String
                 (Metadata_Value (Line, "Request-Accept-Encoding"));
            elsif Starts_With (Line, "Local-Size: ") then
               declare
                  Parsed : Natural := 0;
               begin
                  if Natural_Metadata_Value (Metadata_Value (Line, "Local-Size"), Parsed) then
                     Result.Local_Size := Parsed;
                     Result.Local_Size_Known := True;
                  end if;
               end;
            elsif Starts_With (Line, "Local-Hash: ") then
               Result.Local_Hash := To_Unbounded_String (Metadata_Value (Line, "Local-Hash"));
            elsif Starts_With (Line, "Local-Hash-Algorithm: ") then
               Result.Local_Hash_Algorithm := To_Unbounded_String
                 (Metadata_Value (Line, "Local-Hash-Algorithm"));
            elsif Starts_With (Line, "Resume-Safe: ") then
               Result.Resume_Safe := Metadata_Boolean (Metadata_Value (Line, "Resume-Safe"));
               Result.Resume_Safe_Known := True;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      if Result.Cache_Version_Known and then Result.Cache_Version /= Cache_Metadata_Version then
         return Rejected_Cache_Metadata ("metadata version mismatch");
      end if;
      if Verify_Local_Content
        and then Hash_Algorithm /= Cache_Hash_None
        and then Length (Result.Local_Hash_Algorithm) > 0
        and then To_String (Result.Local_Hash_Algorithm) /= Cache_Hash_Algorithm_Name (Hash_Algorithm)
      then
         return Rejected_Cache_Metadata ("local hash algorithm mismatch");
      end if;
      if Verify_Local_Content then
         if Has_Suffix (Target_Path, ".sitefetch_part") then
            if Result.Local_Size_Known and then Existing_File_Size (Target_Path) /= Result.Local_Size then
               return Rejected_Cache_Metadata ("local size mismatch");
            end if;
            if Length (Result.Local_Hash) > 0
              and then Hash_Algorithm /= Cache_Hash_None
              and then File_Content_Hash (Target_Path, Hash_Algorithm) /= To_String (Result.Local_Hash)
            then
               return Rejected_Cache_Metadata ("local hash mismatch");
            end if;
         else
            if not Result.Local_Size_Known then
               return Rejected_Cache_Metadata ("local size metadata missing");
            elsif Existing_File_Size (Target_Path) /= Result.Local_Size then
               return Rejected_Cache_Metadata ("local size mismatch");
            end if;
            if Hash_Algorithm /= Cache_Hash_None then
               if Length (Result.Local_Hash) = 0
                 or else File_Content_Hash (Target_Path, Hash_Algorithm) /= To_String (Result.Local_Hash)
               then
                  return Rejected_Cache_Metadata ("local hash mismatch");
               end if;
            end if;
         end if;
      end if;
      if Length (Result.ETag) > 0 and then not Result.ETag_Is_Weak then
         Result.ETag_Is_Weak := Is_Weak_ETag (To_String (Result.ETag));
      end if;
      Result.Exists := Length (Result.ETag) > 0
        or else Length (Result.Last_Modified) > 0
        or else Length (Result.Cache_Control) > 0
        or else Length (Result.Expires) > 0
        or else Length (Result.Vary) > 0;
      if not Result.Exists then
         Result.Rejection_Reason := To_Unbounded_String ("cache metadata empty");
      end if;
      if Result.Exists
        and then not Result.Resume_Safe_Known
        and then Has_Suffix (Target_Path, ".sitefetch_part")
      then
         Result.Resume_Safe := Length (Result.Last_Modified) > 0
           or else (Length (Result.ETag) > 0 and then not Result.ETag_Is_Weak);
      end if;
      return Result;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return Rejected_Cache_Metadata ("cache sidecar unreadable");
   end Read_Cache_Metadata;

   function Cache_Reads_Metadata (Limits : Fetch_Options) return Boolean is
   begin
      return Limits.Cache.Mode in Cache_Revalidate | Cache_Offline;
   end Cache_Reads_Metadata;

   function Cache_Writes_Metadata (Limits : Fetch_Options) return Boolean is
   begin
      return Limits.Cache.Mode in Cache_Revalidate | Cache_Refresh;
   end Cache_Writes_Metadata;

   function Cache_Reads_Documents (Limits : Fetch_Options) return Boolean is
   begin
      return Cache_Reads_Metadata (Limits)
        and then Limits.Cache.Resource_Strategy in Cache_All_Resources | Cache_Documents_Only;
   end Cache_Reads_Documents;

   function Cache_Writes_Documents (Limits : Fetch_Options) return Boolean is
   begin
      return Cache_Writes_Metadata (Limits)
        and then Limits.Cache.Resource_Strategy in Cache_All_Resources | Cache_Documents_Only;
   end Cache_Writes_Documents;

   function Cache_Reads_Downloads (Limits : Fetch_Options) return Boolean is
   begin
      return Cache_Reads_Metadata (Limits)
        and then Limits.Cache.Resource_Strategy in Cache_All_Resources | Cache_Downloads_Only;
   end Cache_Reads_Downloads;

   function Cache_Writes_Downloads (Limits : Fetch_Options) return Boolean is
   begin
      return Cache_Writes_Metadata (Limits)
        and then Limits.Cache.Resource_Strategy in Cache_All_Resources | Cache_Downloads_Only;
   end Cache_Writes_Downloads;

   function Effective_Accept_Encoding (Limits : Fetch_Options) return String is
   begin
      if Length (Limits.HTTP.Accept_Encoding) = 0 then
         return Http_Client.Decompression.Supported_Accept_Encoding;
      else
         return To_String (Limits.HTTP.Accept_Encoding);
      end if;
   end Effective_Accept_Encoding;

   function Current_Vary_Request_Value (Field : String; Limits : Fetch_Options) return String is
   begin
      if Field = "user-agent" then
         return To_String (Limits.HTTP.User_Agent);
      elsif Field = "accept-language" then
         return To_String (Limits.HTTP.Accept_Language);
      elsif Field = "accept-encoding" then
         return Effective_Accept_Encoding (Limits);
      else
         return "";
      end if;
   end Current_Vary_Request_Value;

   function Vary_Metadata_Usable
     (Metadata      : Cache_Metadata;
      Limits        : Fetch_Options;
      Reject_Reason : out Unbounded_String) return Boolean
   is
      Vary_Text : constant String := To_String (Metadata.Vary);
      First     : Natural := Vary_Text'First;
      Last      : Natural;
   begin
      Reject_Reason := Null_Unbounded_String;
      while First <= Vary_Text'Last loop
         Last := First;
         while Last <= Vary_Text'Last and then Vary_Text (Last) /= ',' loop
            Last := Last + 1;
         end loop;

         declare
            Field : constant String := To_Lower (Trimmed (Vary_Text (First .. Last - 1)));
         begin
            if Field = "" then
               null;
            elsif Field = "*" then
               Reject_Reason := To_Unbounded_String ("Vary *");
               return False;
            elsif Field = "user-agent" then
               if not Limits.Cache.Vary_Allow.User_Agent then
                  Reject_Reason := To_Unbounded_String ("Vary User-Agent not allowed");
                  return False;
               elsif To_String (Metadata.Request_User_Agent) /= To_String (Limits.HTTP.User_Agent) then
                  Reject_Reason := To_Unbounded_String ("Vary User-Agent mismatch");
                  return False;
               end if;
            elsif Field = "accept-language" then
               if not Limits.Cache.Vary_Allow.Accept_Language then
                  Reject_Reason := To_Unbounded_String ("Vary Accept-Language not allowed");
                  return False;
               elsif To_String (Metadata.Request_Accept_Language)
                 /= Current_Vary_Request_Value (Field, Limits)
               then
                  Reject_Reason := To_Unbounded_String ("Vary Accept-Language mismatch");
                  return False;
               end if;
            elsif Field = "accept-encoding" then
               if not Limits.Cache.Vary_Allow.Accept_Encoding then
                  Reject_Reason := To_Unbounded_String ("Vary Accept-Encoding not allowed");
                  return False;
               elsif To_String (Metadata.Request_Accept_Encoding)
                 /= Current_Vary_Request_Value (Field, Limits)
               then
                  Reject_Reason := To_Unbounded_String ("Vary Accept-Encoding mismatch");
                  return False;
               end if;
            else
               Reject_Reason := To_Unbounded_String ("Vary " & Field & " not allowed");
               return False;
            end if;
         end;

         First := Last + 1;
      end loop;

      return True;
   end Vary_Metadata_Usable;

   function Cache_Metadata_Usable
     (Metadata      : Cache_Metadata;
      Limits        : Fetch_Options;
      Reject_Reason : out Unbounded_String) return Boolean
   is
   begin
      Reject_Reason := Metadata.Rejection_Reason;
      if not Metadata.Exists then
         if Length (Reject_Reason) = 0 then
            Reject_Reason := To_Unbounded_String ("cache metadata empty");
         end if;
         return False;
      elsif Limits.Cache.Require_Metadata_Version and then not Metadata.Cache_Version_Known then
         Reject_Reason := To_Unbounded_String ("metadata version missing");
         return False;
      elsif not Vary_Metadata_Usable (Metadata, Limits, Reject_Reason) then
         return False;
      else
         Reject_Reason := Null_Unbounded_String;
         return True;
      end if;
   end Cache_Metadata_Usable;

   function Cache_Metadata_Fresh (Metadata : Cache_Metadata; Limits : Fetch_Options) return Boolean is
   begin
      return Metadata.Exists
        and then Http_Client.Cache.Is_Fresh
          (Cache_Control     => To_String (Metadata.Cache_Control),
           Expires           => To_String (Metadata.Expires),
           Stored_Time       => Metadata.Sidecar_Time,
           Stored_Time_Known => Metadata.Sidecar_Time_Known,
           Max_Stale_MS      => Limits.Cache.Max_Stale_MS);
   end Cache_Metadata_Fresh;

   function Cache_Metadata_Has_Validators (Metadata : Cache_Metadata) return Boolean is
   begin
      return Length (Metadata.ETag) > 0 or else Length (Metadata.Last_Modified) > 0;
   end Cache_Metadata_Has_Validators;

   procedure Add_Cache_Validators
     (Headers : in out Http_Client.Headers.Header_List;
      Metadata : Cache_Metadata)
   is
   begin
      if Metadata.Exists then
         Http_Client.Cache.Add_Conditional_Validators
           (Headers, To_String (Metadata.ETag), To_String (Metadata.Last_Modified));
      end if;
   end Add_Cache_Validators;

   procedure Write_Cache_Metadata
     (Target_Path  : String;
      URL          : String;
      Final_URL    : String;
      Response     : Http_Client.Responses.Response;
      Limits       : Fetch_Options;
      Resume_Safe  : Boolean := False)
   is
      ETag           : constant String := Http_Client.Responses.Header (Response, "ETag");
      Last_Modified  : constant String := Http_Client.Responses.Header (Response, "Last-Modified");
      Content_Type   : constant String := Http_Client.Responses.Media_Type (Response);
      Content_Length : constant String := Http_Client.Responses.Header (Response, "Content-Length");
      Cache_Control  : constant String := Http_Client.Responses.Header (Response, "Cache-Control");
      Expires        : constant String := Http_Client.Responses.Header (Response, "Expires");
      Vary           : constant String := Http_Client.Responses.Header (Response, "Vary");
      Local_Size     : constant Natural := Existing_File_Size (Target_Path);
      Local_Hash     : constant String := File_Content_Hash (Target_Path, Limits.Cache.Hash_Algorithm);
      ETag_Weak      : constant Boolean := Is_Weak_ETag (ETag);
      Can_Resume     : constant Boolean := Resume_Safe
        and then (Last_Modified /= "" or else (ETag /= "" and then not ETag_Weak));
   begin
      if Has_Cache_Token (Cache_Control, "no-store") then
         Delete_Ordinary_File_If_Present (Cache_Metadata_Path (Target_Path));
         return;
      end if;

      if ETag = "" and then Last_Modified = "" and then Content_Type = "" and then Content_Length = ""
        and then Cache_Control = "" and then Expires = "" and then Vary = ""
      then
         return;
      end if;

      Write_Text
        (Cache_Metadata_Path (Target_Path),
         "Cache-Version: " & Cache_Natural_Image (Cache_Metadata_Version) & Character'Val (10)
         & "URL: " & URL & Character'Val (10)
         & "Final-URL: " & Final_URL & Character'Val (10)
         & "Content-Type: " & Content_Type & Character'Val (10)
         & "Content-Length: " & Content_Length & Character'Val (10)
         & "ETag: " & ETag & Character'Val (10)
         & "ETag-Weak: " & Boolean_Image (ETag_Weak) & Character'Val (10)
         & "Last-Modified: " & Last_Modified & Character'Val (10)
         & "Cache-Control: " & Cache_Control & Character'Val (10)
         & "Expires: " & Expires & Character'Val (10)
         & "Vary: " & Vary & Character'Val (10)
         & "Request-User-Agent: " & Current_Vary_Request_Value ("user-agent", Limits) & Character'Val (10)
         & "Request-Accept-Language: " & Current_Vary_Request_Value ("accept-language", Limits)
         & Character'Val (10)
         & "Request-Accept-Encoding: " & Current_Vary_Request_Value ("accept-encoding", Limits)
         & Character'Val (10)
         & "Local-Size: " & Cache_Natural_Image (Local_Size) & Character'Val (10)
         & "Local-Hash: " & Local_Hash & Character'Val (10)
         & "Local-Hash-Algorithm: " & Cache_Hash_Algorithm_Name (Limits.Cache.Hash_Algorithm)
         & Character'Val (10)
         & "Resume-Safe: " & Boolean_Image (Can_Resume) & Character'Val (10),
         Limits.Safety.Write_Durability);
   exception
      when others =>
         null;
   end Write_Cache_Metadata;

end Sitefetch.Engine.Cache;
