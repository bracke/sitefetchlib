with Ada.Calendar;
with Ada.Strings.Unbounded;

with Http_Client.Headers;
with Http_Client.Responses;

--  Support level: private internal implementation.
--
--  Cache metadata, sidecar, freshness, Vary, and integrity helpers for the
--  crawl engine. This package is internal to sitefetchlib.

private package Sitefetch.Engine.Cache is
   use Ada.Strings.Unbounded;
   type Cache_Metadata is record
      Exists             : Boolean := False;
      URL                : Unbounded_String := Null_Unbounded_String;
      Final_URL          : Unbounded_String := Null_Unbounded_String;
      Content_Type       : Unbounded_String := Null_Unbounded_String;
      Content_Length     : Natural := 0;
      Has_Content_Length : Boolean := False;
      ETag               : Unbounded_String := Null_Unbounded_String;
      ETag_Is_Weak       : Boolean := False;
      Last_Modified      : Unbounded_String := Null_Unbounded_String;
      Cache_Version      : Natural := 0;
      Cache_Version_Known : Boolean := False;
      Cache_Control      : Unbounded_String := Null_Unbounded_String;
      Expires            : Unbounded_String := Null_Unbounded_String;
      Vary                    : Unbounded_String := Null_Unbounded_String;
      Rejection_Reason        : Unbounded_String := Null_Unbounded_String;
      Request_User_Agent      : Unbounded_String := Null_Unbounded_String;
      Request_Accept_Language : Unbounded_String := Null_Unbounded_String;
      Request_Accept_Encoding : Unbounded_String := Null_Unbounded_String;
      Local_Size              : Natural := 0;
      Local_Size_Known   : Boolean := False;
      Local_Hash         : Unbounded_String := Null_Unbounded_String;
      Local_Hash_Algorithm : Unbounded_String := Null_Unbounded_String;
      Resume_Safe        : Boolean := False;
      Resume_Safe_Known  : Boolean := False;
      Sidecar_Time       : Ada.Calendar.Time := Ada.Calendar.Time_Of (1901, 1, 1);
      Sidecar_Time_Known : Boolean := False;
   end record;


   function Cache_Metadata_Path (Target_Path : String) return String;

   function Partial_Download_Path (Target_Path : String) return String;

   function Existing_File_Size (Path_Text : String) return Natural;

   function Cache_Hash_Algorithm_Name (Algorithm : Cache_Hash_Algorithm) return String;

   function File_Content_Hash
     (Path_Text : String;
      Algorithm : Cache_Hash_Algorithm := Cache_Hash_FNV1a_64) return String;

   function Read_Cache_Metadata
     (Target_Path           : String;
      Verify_Local_Content : Boolean := True;
      Hash_Algorithm       : Cache_Hash_Algorithm := Cache_Hash_FNV1a_64) return Cache_Metadata;

   function Cache_Reads_Metadata (Limits : Fetch_Options) return Boolean;

   function Cache_Writes_Metadata (Limits : Fetch_Options) return Boolean;

   function Cache_Reads_Documents (Limits : Fetch_Options) return Boolean;

   function Cache_Writes_Documents (Limits : Fetch_Options) return Boolean;

   function Cache_Reads_Downloads (Limits : Fetch_Options) return Boolean;

   function Cache_Writes_Downloads (Limits : Fetch_Options) return Boolean;

   function Effective_Accept_Encoding (Limits : Fetch_Options) return String;

   function Current_Vary_Request_Value (Field : String; Limits : Fetch_Options) return String;

   function Cache_Metadata_Usable
     (Metadata      : Cache_Metadata;
      Limits        : Fetch_Options;
      Reject_Reason : out Ada.Strings.Unbounded.Unbounded_String) return Boolean;

   function Cache_Metadata_Fresh (Metadata : Cache_Metadata; Limits : Fetch_Options) return Boolean;

   function Cache_Metadata_Has_Validators (Metadata : Cache_Metadata) return Boolean;

   function Resume_Validator (Metadata : Cache_Metadata) return Ada.Strings.Unbounded.Unbounded_String;

   procedure Add_Cache_Validators
     (Headers : in out Http_Client.Headers.Header_List;
      Metadata : Cache_Metadata);

   procedure Write_Cache_Metadata
     (Target_Path  : String;
      URL          : String;
      Final_URL    : String;
      Response     : Http_Client.Responses.Response;
      Limits       : Fetch_Options;
      Resume_Safe  : Boolean := False);
end Sitefetch.Engine.Cache;
