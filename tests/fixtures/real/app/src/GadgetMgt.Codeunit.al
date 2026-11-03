codeunit 50100 "Gadget Mgt."
{
    procedure Describe(GadgetNo: Code[20]): Text
    var
        Gadget: Record "Gadget";
        Unused: Integer;
    begin
        if Gadget.Get(GadgetNo) then
            exit(Gadget.Description);
        exit('');
    end;
}
