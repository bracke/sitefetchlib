with Sitefetch.Content;

package body Sitefetch.Engine.State is
   use Sitefetch.Content;

   procedure Record_Failure
     (Statistics : in out Fetch_Statistics;
      URL        : String;
      Reason     : String := "")
   is
   begin
      Statistics.Failed := Statistics.Failed + 1;
      Statistics.Failed_Downloads.Append
        (Failed_Download'
           (URL    => To_Unbounded_String (URL),
            Reason => To_Unbounded_String (Reason)));

      if Length (Statistics.Failed_URL) = 0 then
         Statistics.Failed_URL := To_Unbounded_String (URL);
         Statistics.Failed_Reason := To_Unbounded_String (Reason);
      end if;
   end Record_Failure;

   protected body Fetch_State is
      procedure Configure_Limits (New_Limits : Fetch_Options) is
      begin
         Limits := New_Limits;
      end Configure_Limits;

      function Page_Limit_Reached return Boolean is
      begin
         return Limits.Crawl.Max_Pages > 0 and then Natural (Visited.Length) >= Limits.Crawl.Max_Pages;
      end Page_Limit_Reached;

      function Failure_Limit_Reached return Boolean is
      begin
         return Limits.Crawl.Max_Failures > 0 and then Current.Failed >= Limits.Crawl.Max_Failures;
      end Failure_Limit_Reached;

      function Byte_Limit_Reached return Boolean is
      begin
         if Limits.Crawl.Max_Bytes = 0 then
            return False;
         elsif Current.Bytes_Written >= Limits.Crawl.Max_Bytes then
            return True;
         else
            return Byte_Reservations >= Limits.Crawl.Max_Bytes - Current.Bytes_Written;
         end if;
      end Byte_Limit_Reached;

      procedure Claim_URL (URL : String; Depth : Natural; Status : out Claim_Status) is
      begin
         if Visited_Set.Contains (URL) then
            Status := Already_Visited;
         elsif Page_Limit_Reached
           or else Failure_Limit_Reached
           or else Byte_Limit_Reached
           or else (Limits.Crawl.Max_Depth > 0 and then Depth > Limits.Crawl.Max_Depth)
         then
            Current.Skipped_Limit := Current.Skipped_Limit + 1;
            Status := Document_Limit_Reached;
         else
            Visited.Append (URL);
            Visited_Set.Include (URL);
            Pending_Set.Exclude (URL);
            Status := Claimed;
         end if;
      end Claim_URL;

      procedure Mark_Visited (URL : String) is
      begin
         if not Visited_Set.Contains (URL) and then not Page_Limit_Reached then
            Visited.Append (URL);
            Visited_Set.Include (URL);
         end if;
         Pending_Set.Exclude (URL);
      end Mark_Visited;

      function Priority_For (URL : String; Kind : Work_Kind) return Work_Priority is
      begin
         if Kind = Work_Document and then Is_Page_Like_URL (URL) then
            return Priority_Page;
         elsif Kind = Work_Document or else Is_Text_Asset_URL (URL) then
            return Priority_Text_Asset;
         elsif Is_Safe_Asset_File_Type (URL) then
            return Priority_Passive_Asset;
         else
            return Priority_Binary_Asset;
         end if;
      end Priority_For;

      procedure Append_Work
        (Target : in out Work_Item_Lists.List;
         URL    : String;
         Depth  : Natural;
         Kind   : Work_Kind)
      is
      begin
         Target.Append
           (Work_Item'
              (URL   => To_Unbounded_String (URL),
               Depth => Depth,
               Kind  => Kind));
      end Append_Work;

      procedure Enqueue (URL : String; Depth : Natural; Kind : Work_Kind) is
      begin
         if not Should_Stop
           and then not Pending_Set.Contains (URL)
         then
            Pending_Set.Include (URL);
            case Priority_For (URL, Kind) is
               when Priority_Page =>
                  Append_Work (Page_Pending, URL, Depth, Kind);
               when Priority_Text_Asset =>
                  Append_Work (Text_Asset_Pending, URL, Depth, Kind);
               when Priority_Passive_Asset =>
                  Append_Work (Passive_Asset_Pending, URL, Depth, Kind);
               when Priority_Binary_Asset =>
                  Append_Work (Binary_Asset_Pending, URL, Depth, Kind);
            end case;
         end if;
      end Enqueue;

      function Has_Pending_Work return Boolean is
      begin
         return not Page_Pending.Is_Empty
           or else not Text_Asset_Pending.Is_Empty
           or else not Passive_Asset_Pending.Is_Empty
           or else not Binary_Asset_Pending.Is_Empty;
      end Has_Pending_Work;

      procedure Pop_Work
        (Source : in out Work_Item_Lists.List;
         URL    : out Unbounded_String;
         Depth  : out Natural;
         Kind   : out Work_Kind)
      is
      begin
         URL := Source.First_Element.URL;
         Depth := Source.First_Element.Depth;
         Kind := Source.First_Element.Kind;
         Source.Delete_First;
      end Pop_Work;

      entry Next_URL
        (URL       : out Unbounded_String;
         Depth     : out Natural;
         Kind      : out Work_Kind;
         Available : out Boolean)
        when Has_Pending_Work or else Active_Count = 0
      is
      begin
         if not Has_Pending_Work or else Should_Stop then
            URL := Null_Unbounded_String;
            Depth := 0;
            Kind := Work_Document;
            Available := False;
         else
            if not Page_Pending.Is_Empty then
               Pop_Work (Page_Pending, URL, Depth, Kind);
            elsif not Text_Asset_Pending.Is_Empty then
               Pop_Work (Text_Asset_Pending, URL, Depth, Kind);
            elsif not Passive_Asset_Pending.Is_Empty then
               Pop_Work (Passive_Asset_Pending, URL, Depth, Kind);
            else
               Pop_Work (Binary_Asset_Pending, URL, Depth, Kind);
            end if;

            Active_Count := Active_Count + 1;
            Pending_Set.Exclude (To_String (URL));
            Available := True;
         end if;
      end Next_URL;

      procedure Complete_URL is
      begin
         if Active_Count > 0 then
            Active_Count := Active_Count - 1;
         end if;
      end Complete_URL;

      procedure Mark_Attempted is
      begin
         Current.Attempted := Current.Attempted + 1;
      end Mark_Attempted;

      procedure Reserve_Download_Budget (Reserved_Bytes : out Natural) is
      begin
         if Limits.Crawl.Max_Bytes = 0 then
            Reserved_Bytes := 0;
         elsif Current.Bytes_Written >= Limits.Crawl.Max_Bytes or else Byte_Limit_Reached then
            Reserved_Bytes := 0;
         else
            Reserved_Bytes := Limits.Crawl.Max_Bytes - Current.Bytes_Written - Byte_Reservations;
            Byte_Reservations := Byte_Reservations + Reserved_Bytes;
         end if;
      end Reserve_Download_Budget;

      procedure Release_Download_Budget (Reserved_Bytes : Natural) is
      begin
         if Reserved_Bytes > Byte_Reservations then
            Byte_Reservations := 0;
         else
            Byte_Reservations := Byte_Reservations - Reserved_Bytes;
         end if;
      end Release_Download_Budget;

      procedure Mark_Written (Byte_Count : Natural := 0; Reserved_Bytes : Natural := 0) is
      begin
         Release_Download_Budget (Reserved_Bytes);
         Current.Written := Current.Written + 1;
         if Byte_Count > Natural'Last - Current.Bytes_Written then
            Current.Bytes_Written := Natural'Last;
         else
            Current.Bytes_Written := Current.Bytes_Written + Byte_Count;
         end if;
      end Mark_Written;

      procedure Mark_External is
      begin
         Current.Skipped_External := Current.Skipped_External + 1;
      end Mark_External;

      procedure Mark_Unsupported is
      begin
         Current.Skipped_Unsupported := Current.Skipped_Unsupported + 1;
      end Mark_Unsupported;

      procedure Mark_Failed (URL : String; Reason : String) is
      begin
         Record_Failure (Current, URL, Reason);
      end Mark_Failed;

      procedure Mark_Limited is
      begin
         Current.Skipped_Limit := Current.Skipped_Limit + 1;
      end Mark_Limited;

      function Should_Stop return Boolean is
      begin
         return Page_Limit_Reached
           or else Failure_Limit_Reached
           or else Byte_Limit_Reached;
      end Should_Stop;

      function Snapshot return Fetch_Statistics is
      begin
         return Current;
      end Snapshot;
   end Fetch_State;
end Sitefetch.Engine.State;
