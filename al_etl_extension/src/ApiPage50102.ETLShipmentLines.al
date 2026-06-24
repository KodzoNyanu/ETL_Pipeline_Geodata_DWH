page 50102 "ETL Shipment Lines API"
{
    PageType = API;
    APIPublisher = 'etlpipeline';
    APIGroup = 'warehouse';
    APIVersion = 'v1.0';
    EntityName = 'etlShipmentLine';
    EntitySetName = 'etlShipmentLines';
    SourceTable = "ETL Shipment Line";
    DelayedInsert = true;
    ODataKeyFields = "Document No", "Line No";

    layout
    {
        area(Content)
        {
            repeater(GroupName)
            {
                field(documentNo; Rec."Document No") { Caption = 'documentNo'; }
                field(lineNo; Rec."Line No") { Caption = 'lineNo'; }
                field(articleId; Rec."Article Id") { Caption = 'articleId'; }
                field(quantity; Rec."Quantity") { Caption = 'quantity'; }
                field(locationCode; Rec."Location Code") { Caption = 'locationCode'; }
                field(etlLoadedAt; Rec."ETL Loaded At") { Caption = 'etlLoadedAt'; }
            }
        }
    }
}
