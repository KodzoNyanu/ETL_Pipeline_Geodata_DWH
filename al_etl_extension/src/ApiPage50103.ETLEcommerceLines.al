page 50103 "ETL Ecommerce Lines API"
{
    PageType = API;
    APIPublisher = 'etlpipeline';
    APIGroup = 'warehouse';
    APIVersion = 'v1.0';
    EntityName = 'etlEcommerceLine';
    EntitySetName = 'etlEcommerceLines';
    SourceTable = "ETL Ecommerce Line";
    DelayedInsert = true;
    ODataKeyFields = "Invoice No", "Line No";

    layout
    {
        area(Content)
        {
            repeater(GroupName)
            {
                field(invoiceNo; Rec."Invoice No") { Caption = 'invoiceNo'; }
                field(lineNo; Rec."Line No") { Caption = 'lineNo'; }
                field(stockCode; Rec."Stock Code") { Caption = 'stockCode'; }
                field(description; Rec."Description") { Caption = 'description'; }
                field(quantity; Rec."Quantity") { Caption = 'quantity'; }
                field(unitPrice; Rec."Unit Price") { Caption = 'unitPrice'; }
                field(totalAmount; Rec."Total Amount") { Caption = 'totalAmount'; }
                field(customerId; Rec."Customer Id") { Caption = 'customerId'; }
                field(country; Rec."Country") { Caption = 'country'; }
                field(invoiceDate; Rec."Invoice Date") { Caption = 'invoiceDate'; }
                field(etlLoadedAt; Rec."ETL Loaded At") { Caption = 'etlLoadedAt'; }
            }
        }
    }
}
