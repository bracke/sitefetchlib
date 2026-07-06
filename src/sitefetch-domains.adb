with Ada.Characters.Handling;

with Http_Client.URI;

package body Sitefetch.Domains is
   function To_Lower (Item : String) return String renames Ada.Characters.Handling.To_Lower;

   function Normalized_Host (URL : String) return String is
      Host : constant String := Domain_Of (URL);
   begin
      if Http_Client.URI.Raw_Authority_Host_Has_Non_ASCII (URL) then
         return "";
      elsif Http_Client.URI.Is_Valid_ASCII_Host (Host) then
         return Host;
      else
         return "";
      end if;
   end Normalized_Host;

   function Is_Child_Of (Child_Host : String; Parent_Host : String) return Boolean
     with SPARK_Mode => On
   is
   begin
      return Child_Host'Length > Parent_Host'Length
        and then Child_Host
          (Child_Host'Last - Parent_Host'Length .. Child_Host'Last) = "." & Parent_Host;
   end Is_Child_Of;

   function Has_Dot (Host : String) return Boolean
     with SPARK_Mode => On
   is
   begin
      for Item of Host loop
         if Item = '.' then
            return True;
         end if;
      end loop;

      return False;
   end Has_Dot;

   function Last_Label (Host : String) return String
     with SPARK_Mode => On
   is
   begin
      for Index in reverse Host'Range loop
         if Host (Index) = '.' then
            if Index = Host'Last then
               return "";
            else
               return Host (Index + 1 .. Host'Last);
            end if;
         end if;
      end loop;

      return Host;
   end Last_Label;

   function Parent_Prefix (Host : String; Suffix : String) return String
     with SPARK_Mode => On
   is
   begin
      if Suffix = "" or else Host'Length <= Suffix'Length + 1
        or else not Is_Child_Of (Host, Suffix)
      then
         return "";
      else
         declare
            Cut : constant Positive := Host'Last - Suffix'Length - 1;
         begin
            return Host (Host'First .. Cut);
         end;
      end if;
   end Parent_Prefix;

   function Is_Known_Public_Suffix (Host : String) return Boolean
     with SPARK_Mode => On
   is
   begin
      return Host in
        "co.uk" | "org.uk" | "ac.uk" | "gov.uk" | "ltd.uk" | "plc.uk"
        | "com.au" | "net.au" | "org.au" | "edu.au" | "gov.au"
        | "co.nz" | "org.nz" | "net.nz" | "ac.nz" | "govt.nz"
        | "com.br" | "net.br" | "org.br"
        | "com.mx" | "org.mx" | "gob.mx"
        | "co.jp" | "ne.jp" | "or.jp" | "ac.jp" | "go.jp"
        | "co.kr" | "ne.kr" | "or.kr" | "ac.kr" | "go.kr"
        | "com.cn" | "net.cn" | "org.cn" | "gov.cn"
        | "com.tr" | "org.tr" | "net.tr" | "gov.tr"
        | "github.io" | "pages.dev" | "workers.dev" | "cloudfront.net"
        | "appspot.com" | "firebaseapp.com" | "web.app" | "vercel.app"
        | "netlify.app" | "herokuapp.com" | "azurewebsites.net";
   end Is_Known_Public_Suffix;

   function Is_IP_Literal (Host : String) return Boolean is
   begin
      return Http_Client.URI.Is_Valid_ASCII_Host (Host)
        and then Http_Client.URI.Kind_Of_ASCII_Host (Host) in
          Http_Client.URI.IPv4_Literal | Http_Client.URI.IPv6_Literal;
   end Is_IP_Literal;

   function Looks_Like_IP_Literal (Host : String) return Boolean
     with SPARK_Mode => On
   is
      Has_Digit : Boolean := False;
      Has_Dot   : Boolean := False;
   begin
      for Item of Host loop
         if Item = ':' then
            return True;
         elsif Item = '.' then
            Has_Dot := True;
         elsif Item in '0' .. '9' then
            Has_Digit := True;
         else
            return False;
         end if;
      end loop;

      return Has_Digit and then Has_Dot;
   end Looks_Like_IP_Literal;

   function Public_Suffix_For_Normalized_Host (Host : String) return String
     with SPARK_Mode => On
   is
      Best_Start : Natural := 0;
   begin
      if Host = "" then
         return "";
      elsif Looks_Like_IP_Literal (Host) then
         return Host;
      elsif not Has_Dot (Host) then
         return Host;
      end if;

      if Is_Known_Public_Suffix (Host) then
         return Host;
      end if;

      for Index in Host'Range loop
         if Host (Index) = '.' and then Index < Host'Last then
            declare
               Candidate : constant String := Host (Index + 1 .. Host'Last);
            begin
               if Is_Known_Public_Suffix (Candidate) then
                  Best_Start := Index + 1;
                  exit;
               end if;
            end;
         end if;
      end loop;

      if Best_Start = 0 then
         return Last_Label (Host);
      else
         return Host (Best_Start .. Host'Last);
      end if;
   end Public_Suffix_For_Normalized_Host;

   function Registrable_Domain_For_Normalized_Host (Host : String) return String
     with SPARK_Mode => On
   is
      Suffix : constant String := Public_Suffix_For_Normalized_Host (Host);
      Prefix : constant String := Parent_Prefix (Host, Suffix);
      Label  : constant String := Last_Label (Prefix);
   begin
      if Host = "" or else Looks_Like_IP_Literal (Host)
        or else Suffix = "" or else Prefix = "" or else Label = ""
        or else Suffix'Length >= Natural'Last - 1
        or else Label'Length > Natural'Last - Suffix'Length - 1
      then
         return "";
      else
         declare
            Normal_Label  : constant String (1 .. Label'Length) := Label;
            Normal_Suffix : constant String (1 .. Suffix'Length) := Suffix;
         begin
            return Normal_Label & "." & Normal_Suffix;
         end;
      end if;
   end Registrable_Domain_For_Normalized_Host;

   function Is_Internal_Host
     (Root_Host     : String;
      Candidate_Host : String;
      Policy        : Domain_Policy := Domain_Exact_And_Subdomains) return Boolean
     with SPARK_Mode => On
   is
      Root_Reg  : constant String := Registrable_Domain_For_Normalized_Host (Root_Host);
      Child_OK  : constant Boolean :=
        Root_Reg /= ""
        and then Is_Child_Of (Candidate_Host, Root_Host);
      Parent_OK : constant Boolean :=
        Policy = Domain_Include_Parents
        and then Root_Reg /= ""
        and then Candidate_Host = Root_Reg
        and then Is_Child_Of (Root_Host, Candidate_Host);
   begin
      return Root_Host /= ""
        and then Candidate_Host /= ""
        and then (Candidate_Host = Root_Host
                  or else Child_OK
                  or else Parent_OK);
   end Is_Internal_Host;

   function Public_Suffix (Host : String) return String is
      Normal_Host : constant String := To_Lower (Host);
   begin
      if Normal_Host = "" or else not Http_Client.URI.Is_Valid_ASCII_Host (Normal_Host) then
         return "";
      elsif Is_IP_Literal (Normal_Host) then
         return Normal_Host;
      else
         return Public_Suffix_For_Normalized_Host (Normal_Host);
      end if;
   end Public_Suffix;

   function Registrable_Domain (Host : String) return String is
      Normal_Host : constant String := To_Lower (Host);
   begin
      if Normal_Host = "" or else not Http_Client.URI.Is_Valid_ASCII_Host (Normal_Host)
        or else Is_IP_Literal (Normal_Host)
      then
         return "";
      else
         return Registrable_Domain_For_Normalized_Host (Normal_Host);
      end if;
   end Registrable_Domain;

   function Is_Internal
     (Root_Host     : String;
      Candidate_URL : String;
      Policy        : Domain_Policy := Domain_Exact_And_Subdomains) return Boolean
   is
      Root      : constant String := Normalized_Host (Root_Host);
      Candidate : constant String := Normalized_Host (Candidate_URL);
   begin
      return Is_Internal_Host (Root, Candidate, Policy);
   end Is_Internal;
end Sitefetch.Domains;
