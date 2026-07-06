with Ada.Containers.Doubly_Linked_Lists;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

--  Support level: private internal implementation.
--
--  Crawl state, visited/pending URL tracking, work queue priority, and
--  statistics mutation for the crawl engine.

private package Sitefetch.Engine.State is
   use Ada.Strings.Unbounded;

   type Claim_Status is (Claimed, Already_Visited, Document_Limit_Reached);

   type Work_Kind is (Work_Document, Work_Download);

   package URL_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (Element_Type        => String,
      Hash                => Ada.Strings.Hash,
      Equivalent_Elements => "=");

   procedure Record_Failure
     (Statistics : in out Fetch_Statistics;
      URL        : String;
      Reason     : String := "");

   type Work_Priority is
     (Priority_Page,
      Priority_Text_Asset,
      Priority_Passive_Asset,
      Priority_Binary_Asset);

   type Work_Item is record
      URL   : Unbounded_String := Null_Unbounded_String;
      Depth : Natural := 0;
      Kind  : Work_Kind := Work_Document;
   end record;

   package Work_Item_Lists is new Ada.Containers.Doubly_Linked_Lists
     (Element_Type => Work_Item);

   protected type Fetch_State is
      procedure Configure_Limits (New_Limits : Fetch_Options);
      procedure Claim_URL (URL : String; Depth : Natural; Status : out Claim_Status);
      procedure Mark_Visited (URL : String);
      procedure Enqueue (URL : String; Depth : Natural; Kind : Work_Kind);
      entry Next_URL
        (URL       : out Unbounded_String;
         Depth     : out Natural;
         Kind      : out Work_Kind;
         Available : out Boolean);
      procedure Complete_URL;
      procedure Mark_Attempted;
      procedure Reserve_Download_Budget (Reserved_Bytes : out Natural);
      procedure Release_Download_Budget (Reserved_Bytes : Natural);
      procedure Mark_Written (Byte_Count : Natural := 0; Reserved_Bytes : Natural := 0);
      procedure Mark_External;
      procedure Mark_Unsupported;
      procedure Mark_Failed (URL : String; Reason : String);
      procedure Mark_Limited;
      function Should_Stop return Boolean;
      function Snapshot return Fetch_Statistics;
   private
      Visited      : Link_List;
      Visited_Set  : URL_Sets.Set;
      Pending_Set  : URL_Sets.Set;
      Page_Pending          : Work_Item_Lists.List;
      Text_Asset_Pending    : Work_Item_Lists.List;
      Passive_Asset_Pending : Work_Item_Lists.List;
      Binary_Asset_Pending  : Work_Item_Lists.List;
      function Has_Pending_Work return Boolean;
      Limits         : Fetch_Options := Default_Fetch_Options;
      Active_Count   : Natural := 0;
      Byte_Reservations : Natural := 0;
      Current        : Fetch_Statistics;
   end Fetch_State;
end Sitefetch.Engine.State;
