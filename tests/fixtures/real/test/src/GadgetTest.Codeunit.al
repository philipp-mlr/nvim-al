codeunit 50150 "Gadget Test"
{
    Subtype = Test;

    [Test]
    procedure DescribeReturnsDescription()
    var
        Gadget: Record "Gadget";
        GadgetMgt: Codeunit "Gadget Mgt.";
    begin
        Gadget."No." := 'G1';
        Gadget.Description := 'Thing';
        Gadget.Insert();
        if GadgetMgt.Describe('G1') <> 'Thing' then
            Error('unexpected');
    end;

    [Test]
    procedure SecondTest()
    begin
        // cursor tests put the cursor in here
        Error('unexpected');
    end;

    local procedure Helper()
    begin
    end;
}
